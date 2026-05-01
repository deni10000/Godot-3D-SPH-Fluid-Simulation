#[compute]
#version 450
const float PI = 3.1415926;

layout(push_constant, std430) uniform Params {
    int run_mode;
    float radius;
    float smoothing_radius;
    float gravity;
    float default_density;
    float pressure_multiply;
    float damping;
    uint  count;
    uint  hash_size;
    float  mass;
    float delta;
    float _length;
    float width;
    float height;
    float viscosity_multiplier;
    float mouse_x;
    float mouse_y;
} pc;

layout(set = 0, binding = 0, std430) restrict buffer ParticleBuffer {
    vec3 positions[];
}  particleBuf;

layout(set = 0, binding = 1, std430) restrict buffer PredictedBuffer {
    vec3 pred_positions[];
}  predictedBuf;

layout(set = 0, binding = 2, std430) restrict buffer VelocityBuffer {
    vec3 velocity[];
}  velocityBuf;

layout(set = 0, binding = 3, std430) restrict buffer DensityBuffer {
    float density[];
} densityBuf;

layout(set = 0, binding = 4, std430) restrict buffer HashCountBuffer {
    uint hash_count[];
}  hashCountBuf;

layout(set = 0, binding = 5, std430) restrict buffer PrefSumHashBuffer {
    uint pref_sum_hash_count[];
}  prefSumHashBuf;

layout(set = 0, binding = 7, std430) restrict buffer PrefSumHashBuffer2 {
    uint pref_sum_hash_count[];
}  prefSumHashBuf2;

layout(set = 0, binding = 6, std430) restrict buffer HashIndexBuffer {
    uint hash_indexes[];
} hashIndexBuf;

layout(set = 0, binding = 9, std430) restrict buffer ForceBuffer {
    vec3 forces[];
};

layout(set = 0, binding = 11) uniform sampler3D collision_sdf;

layout(set = 0, binding = 10, std430) restrict buffer MultiMeshBuffer {
    float instances[];
};



void draw_sphere(uint i) {
    vec3 dop = particleBuf.positions[i];
    instances[16 * i + 3] = dop[0];
    instances[16 * i + 7] = dop[1];
    instances[16 * i + 11] = dop[2];


    float dens = densityBuf.density[i];
    vec4 color;
    float ratio;
    if (dens >= pc.default_density) {
        ratio = pc.default_density / dens;
        color = vec4(ratio, ratio, 1, 1);
    } else {
        ratio = dens / pc.default_density;
        color = vec4(1, 1, ratio, 1);
    }

    instances[16 * i + 12] = color.x;
    instances[16 * i + 13] = color.y;
    instances[16 * i + 14] = color.z;
    instances[16 * i + 15] = 1;
}


float spiky_kernel_pow2(float dst, float radius)
{
	if (dst < radius)
	{
		float scale = 15 / (2 * PI * pow(radius, 5));
		float v = radius - dst;
		return v * v * scale;
	}
	return 0;
}

float scale2 = 45 / (pow(pc.smoothing_radius, 6) * PI);
float derivative_spiky_pow3(float dst)
{
	if (dst <= pc.smoothing_radius)
	{
		float v = pc.smoothing_radius - dst;
		return -v * v * scale2;
	}
	return 0;
}

float mult1 = 315.0 / (64.0 * PI * pow(pc.smoothing_radius, 9.0));
float mult2 = pow(pc.smoothing_radius, 2);
float density_kernel(float d) {
    if (d >= pc.smoothing_radius) return 0;
    return mult1 * pow(mult2 - d * d, 3.0);
    // return spiky_kernel_pow2(d, h);
    // if (d >= h) return 0.0;
    // float v = (3.14159265359 * pow(h, 4.0)) / 6.0;
    // return pow(h - d, 2.0) / v;
}

float scale = 45 / (pow(pc.smoothing_radius, 6) * PI);
float viscosity_kernel(float dst) {
    if (dst <= pc.smoothing_radius)
	{
		float v = pc.smoothing_radius - dst;
		return v * scale;
	}
	return 0;
}

float density_derivative(float d) {
    return derivative_spiky_pow3(d);
    // if (d >= h) return 0.0;
    // float scale = 12.0 / (pow(h, 4.0) * 3.14159265359);
    // return (d - h) * scale;
}

float density_to_pressure(float rho) {
   return max(0, (rho - pc.default_density) * pc.pressure_multiply);
//    return pc.pressure_multiply * (pow(rho / pc.default_density, 7.0) - 1 );
}

float shared_pressure(float rho1, float rho2) {
    return (density_to_pressure(rho1) + density_to_pressure(rho2)) * 0.5;
}

uvec3 coord_to_cell_pos(vec3 pos) { 
    ivec3 ip = ivec3(floor(pos / pc.smoothing_radius));
    return uvec3(ip);
}

uint cell_hash(uvec3 cell) {
    uint a = uint(cell.x) * 73856093u;
    uint b = uint(cell.y) * 19349663u;
    uint c = uint(cell.z) * 83492791u;
    return a + b + c;
}



uint get_cell_count(uint h) {
    return hashCountBuf.hash_count[h];
}

void clear_hash_buffer(uint i) {
    hashCountBuf.hash_count[i] = 0;
    prefSumHashBuf.pref_sum_hash_count[i] = 0;
    prefSumHashBuf2.pref_sum_hash_count[i] = 0;
}

void fill_hash_count_buffer(uint i) {
    uint h = cell_hash(coord_to_cell_pos(predictedBuf.pred_positions[i])) % pc.hash_size;
    atomicAdd(hashCountBuf.hash_count[h], 1u);
    atomicAdd(prefSumHashBuf.pref_sum_hash_count[h], 1u);
}

void fill_hash_indexes(uint i) {
    uint h = cell_hash(coord_to_cell_pos(predictedBuf.pred_positions[i])) % pc.hash_size;                    
    uint val = atomicAdd(prefSumHashBuf2.pref_sum_hash_count[h], -1u);                                  
    hashIndexBuf.hash_indexes[val - 1u] = i;  
}

void compute_density(uint j) {
    vec3 pos_j = predictedBuf.pred_positions[j];
    float rho = 0.0;
    uvec3 base = coord_to_cell_pos(pos_j);
    for (int dx = -1; dx <= 1; ++dx) {
        for (int dy = -1; dy <= 1; ++dy) {
            for(int dz = -1; dz <= 1; ++dz) {
                uvec3 cell = base + uvec3(dx, dy, dz);
                uint h = cell_hash(cell) % pc.hash_size;
                uint start = prefSumHashBuf.pref_sum_hash_count[h] - 1;
                uint cnt   = get_cell_count(h);
                for (uint k = 0u; k < cnt; ++k) {
                    uint i = hashIndexBuf.hash_indexes[start - k];
                    float d = length(predictedBuf.pred_positions[i] - pos_j);
                    rho += density_kernel(d);
                }
            }
        }
    }
    densityBuf.density[j] = rho;
}

// vec2 add_viscosity_force(uint j) {
//     vec2 force = vec2(0, 0);
//     vec2 pos_j = predictedBuf.pred_positions[j];
//     uvec2 base = coord_to_cell_pos(predictedBuf.pred_positions[j]);

//     for (int dx = -1; dx <= 1; ++dx) {
//         for (int dy = -1; dy <= 1; ++dy) {
//             uvec2 cell = base + uvec2(dx, dy);
//             uint h = cell_hash(cell) % pc.hash_size;
//             uint start = prefSumHashBuf.pref_sum_hash_count[h] - 1;
//             uint cnt   = get_cell_count(h);
//             for (uint k = 0u; k < cnt; ++k) {
//                 uint i = hashIndexBuf.hash_indexes[start - k];
//                 float d = length(predictedBuf.pred_positions[i] - pos_j);
//                 rho += density_kernel(pc.smoothing_radius, d) * pc.mass;
//             }
//         }
//     }
//     densityBuf.density[j] = rho;
// } 

void compute_force(uint j) {
    vec3 pos_j = predictedBuf.pred_positions[j];
    float rho_j = max(densityBuf.density[j], 0.001);

    float Pj    = density_to_pressure(rho_j);
    vec3 force = vec3(0.0);
    uvec3 base = coord_to_cell_pos(pos_j);
    vec3 viscosity_force = vec3(0.0);
    for (int dx = -1; dx <= 1; ++dx) {
        for (int dy = -1; dy <= 1; ++dy) {
            for(int dz = -1; dz <= 1; ++dz) {
                uvec3 cell = base + uvec3(dx, dy, dz);
                uint h = cell_hash(cell) % pc.hash_size;
                uint start = prefSumHashBuf.pref_sum_hash_count[h] - 1;
                uint cnt   = get_cell_count(h);
                for (uint k = 0u; k < cnt; ++k) {
                    uint i = hashIndexBuf.hash_indexes[start - k];
                    if (i == j) continue;
                    float rho_i = max(0.001, densityBuf.density[i]);

                    vec3 rij = predictedBuf.pred_positions[i] - pos_j;
                    float d = length(rij);
                    // if (d == 0) continue;
                    float slope = density_derivative(d);
                    vec3 dir;
                    if (d > 0.0)  {
                       dir = rij / d;
                    } else {
                        dir = vec3(i - 2 * j, i + 3 * j, j - i);
                        dir = dir / length(dir);
                    }
                    // d = max(d, 0.0001);
                    float Pi = density_to_pressure(rho_i);
                    // float Pavg = (Pi + Pj) * 0.5;

                    viscosity_force += (velocityBuf.velocity[i] - velocityBuf.velocity[j]) * viscosity_kernel(d) / rho_i;

                    // force += Pavg * dir * slope * pc.mass / rho_i;
                    force += (Pj / (rho_j * rho_j) + Pi / (rho_i * rho_i)) * dir * slope;
                    // force += viscosity_force * pc.viscosity_multiplier;
                }
            }
        }
    }
    forces[j] = force + pc.viscosity_multiplier * viscosity_force / rho_j;
}

void predict(uint id, float delta) {
    // vec3 pos = particleBuf.positions[id];
    // velocityBuf.velocity[id] -= vec3(0.0, pc.gravity, 0) * delta;
    predictedBuf.pred_positions[id] = particleBuf.positions[id] + velocityBuf.velocity[id] * delta;
}


void correct(uint id, float delta) {
    vec3 pos = particleBuf.positions[id];
    vec3 vel = velocityBuf.velocity[id];
    vec3 mouse_pos = vec3(pc.mouse_x, pc.mouse_y, 0);
    vec3 dir = pos - mouse_pos;
    float d = length(dir);
    vec3 F = forces[id];  //+ (dir / d) * density_kernel(200, d) * 200000;
    vel += F * delta;
    vel -= vec3(0.0, pc.gravity, 0) * delta;
    

    // vec3 uv = pos / vec3(pc._length, pc.height, pc.width);

    // float dist = texture(collision_sdf, uv).r;

    // vec3 color = normal * 0.5 + 0.5;
    // instances[16 * id + 12] = dist;
    // instances[16 * id + 13] = -dist;
    // instances[16 * id + 14] = color.z;

    vec3 move_vec = vel * delta;
    vec3 tex_size = textureSize(collision_sdf, 0);
    vec3 e = 1.0 / tex_size;
    float cell_size = e.x * pc._length / 2;

    int steps = int(length(move_vec) / cell_size) + 1;
    vec3 step = move_vec / steps;
    if (steps > 16) {
        step = normalize(move_vec) * cell_size;
        steps = 16;
        vel = (step * float(steps)) / delta;
    }
    vec3 pred_pos = pos;
    vec3 size = vec3(pc._length, pc.height, pc.width);
    for (int i = 1; i < steps + 1; i++) {
        pred_pos = pos + step;

        vec3 uv = pred_pos / size;
        float dist = texture(collision_sdf, uv).r;

        if (dist < 0.0) { 
            vec3 grad = vec3(
                texture(collision_sdf, uv + vec3(e.x, 0, 0)).r - texture(collision_sdf, uv - vec3(e.x, 0, 0)).r,
                texture(collision_sdf, uv + vec3(0, e.y, 0)).r - texture(collision_sdf, uv - vec3(0, e.y, 0)).r,
                texture(collision_sdf, uv + vec3(0, 0, e.z)).r - texture(collision_sdf, uv - vec3(0, 0, e.z)).r
            );
            
            if (length(grad) < 0.000001) {
                grad = vec3(0.0, 1.0, 0.0);
            }
            vec3 normal = normalize(grad);

            float v_dot_n = dot(vel, normal);

            
            if (v_dot_n < 0.0) {
                vel -= v_dot_n * normal;
                vel += 0.02 * normal;
                
                step -= dot(step, normal) * normal; 
                // vec3 color = normal * 0.5 + 0.5;
                // instances[16 * id + 12] = color.x;
                // instances[16 * id + 13] = color.y;
                // instances[16 * id + 14] = color.z;
            } 
            // else {
            //     instances[16 * id + 13] = 1.0;
            //     instances[16 * id + 13] = 1.0;
            //     instances[16 * id + 14] = 1.0;
            // }

        }
        
        pos += step;
        uv = pos / size;
        dist = texture(collision_sdf, uv).r;
        while (dist < 0) {
            vec3 grad = vec3(
                texture(collision_sdf, uv + vec3(e.x, 0, 0)).r - texture(collision_sdf, uv - vec3(e.x, 0, 0)).r,
                texture(collision_sdf, uv + vec3(0, e.y, 0)).r - texture(collision_sdf, uv - vec3(0, e.y, 0)).r,
                texture(collision_sdf, uv + vec3(0, 0, e.z)).r - texture(collision_sdf, uv - vec3(0, 0, e.z)).r
            );
            
            if (length(grad) < 0.000001) {
                grad = vec3(0.0, 1.0, 0.0);
            }
            vec3 normal = normalize(grad);

            pos -= (dist - 0.003) * normal;
            uv = pos / size;
            dist = texture(collision_sdf, uv).r;
        }   
    }    

    // uv = pos / vec3(pc._length, pc.height, pc.width);

    // pos += vel * delta;
    float width = pc.width; 
    float height = pc.height;
    float _length = pc._length;
    // boundary  
    if (pos.x < 0)      { pos.x = 0; vel.x *= -pc.damping; }
    if (pos.y > height)      { pos.y = height; vel.y *= -pc.damping; }
    if (pos.x > _length)          { pos.x = _length; vel.x *= -pc.damping; }
    if (pos.y < 0)          { pos.y = 0; vel.y *= -pc.damping; }
    if (pos.z < 0)      { pos.z = 0; vel.z *= -pc.damping; }
    if (pos.z > width)          { pos.z = width; vel.z *= -pc.damping; }


    particleBuf.positions[id] = pos;
    velocityBuf.velocity[id]  = vel;
}

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;
void main() {
	uint i = gl_GlobalInvocationID.x;
    switch(pc.run_mode) {
        case -1:
            if (i < pc.hash_size) {
                // clear_circle(i);
            }
            break;
        case 0:
            if (i < pc.hash_size) {
                clear_hash_buffer(i);
            }
            break;
        case 1:
            if (i < pc.count) {
                predict(i, pc.delta);
                fill_hash_count_buffer(i);
            }
            break;
        case 2:
            if (i < pc.count) {
                fill_hash_indexes(i);
            }
            break;
        case 3:
            if (i < pc.count) {
                // integrate(i, pc.delta);
            }
            break;
        case 4:
            if (i < pc.count) {
                compute_density(i);
            }
            break;
        case 5:
            if (i < pc.count) {
                compute_force(i);
            }
            break;
        case 6:
             if (i < pc.count) {
                correct(i, pc.delta);
                draw_sphere(i);
            }
            break;
    }
}
