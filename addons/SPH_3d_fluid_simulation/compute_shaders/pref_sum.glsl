#[compute]
#version 450
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer InputBuffer {
    uint in_data[];
};

layout(set = 0, binding = 1, std430) restrict buffer OutputBuffer {
    uint out_data[];
};

layout(push_constant) uniform Params {
    uint offset;
} pc;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= in_data.length()) {
        return;
    }

    if (i >= pc.offset) {
        out_data[i] = in_data[i] + in_data[i - pc.offset];
    } else {
        out_data[i] = in_data[i];
    }
}
