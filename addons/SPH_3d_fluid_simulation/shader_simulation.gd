@tool
extends Node3D

var profiler_mode := false
@export
var radius: float = 0.1 / 8
@export
var smoothing_radius: float = 0.1
@export
var count: int = 40000:
	set(val):
		count = val
		set_particles()

var spacing = 10:
	set(val):
		spacing = val
		set_particles()	
var shader_local_size = 256

@export
var viscosity_multiplier: float = 20

var int_size = 4
var hash_oversizing = 2

@export
var length = 4.0:
	set(val):
		length = val
		set_multimesh_aabb()
		
@export
var width = 2.0:
	set(val):
		width = val
		set_multimesh_aabb()
@export
var height = 2.0:
	set(val):
		height = val
		set_multimesh_aabb()

@export
var box_scale = 8.0

var output_tex_uniform :RDUniform
var output_tex := RID()
#var fmt := RDTextureFormat.new() 

var view := RDTextureView.new()

var positions: PackedVector4Array = []
var shader :RID
var pipeline :RID
var sum_shader: RID
var sum_pipeline: RID
var uniform_set :RID
var first_step_sum_uniform_set: RID
var second_step_sum_uniform_set: RID

var positions_buffer: RID
var predicated_positions_buffer: RID
var velocity_buffer: RID
var density_buffer: RID
var hash_count_buffer: RID
var pref_sum_hash_count_buffer: RID
var pref_sum_hash_count_buffer2: RID
var hash_indexes_buffer: RID
var force_buffer: RID

var positions_uniform :RDUniform
var predicated_positions_uniform :RDUniform
var velocity_uniform :RDUniform
var density_uniform :RDUniform
var hash_count_uniform :RDUniform
var pref_sum_hash_count_uniform :RDUniform
var pref_sum_hash_count_uniform2 :RDUniform
var hash_indexes_uniform :RDUniform
var in_hash_pref_uniform: RDUniform
var out_has_pref_uniform: RDUniform
var force_buffer_uniform: RDUniform

var gravity: float = 0.4
var default_density: float = 10000
var pressure_multiply: float = 2
var damping: float = 0.3
var rows = 20
var mass: float = 100:
	set(val):
		mass = val

var rd := RenderingServer.get_rendering_device()

var hash_count: PackedInt32Array
var pref_sum_hash_count: PackedInt32Array
var hash_indexes: PackedInt32Array

func _ready() -> void:
	if profiler_mode:
		rd = RenderingServer.create_local_rendering_device()
	#%TextureRect.size = Vector2(width, height)
	#%TextureRect.position = Vector2(0, 0)
	
	set_particles()
	rebuild_buffers()
	
	#fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	#fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	#fmt.width = img_size_x
	#fmt.height = img_size_y
	#fmt.depth = 1
	#fmt.array_layers = 1
	#fmt.mipmaps = 1
	#fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
				#| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
				#| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
				#| RenderingDevice.TEXTURE_USAGE_CPU_READ_BIT
				
	#fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	#fmt.width = img_size_x
	#fmt.height = img_size_y
	#fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
					
	
	#for i in range(count):
		#positions.append(Vector3(randi() % 600 , randi() % 600, 0.5	))
	#rebuild_buffers()

func set_particles():
	positions.clear()
	var diameter = 2 * radius + spacing
	for i in range(count):
		positions.append(Vector4(randf() * length , height - randf() * 0.1, randf() * width, 0))
	rebuild_buffers()

func params_to_byte_array(params):
	var data: PackedByteArray
	for x in params:
		if x is int:
			var dop: PackedInt32Array = [x] 
			data.append_array(dop.to_byte_array())
		else:
			var dop: PackedFloat32Array = [x]
			data.append_array(dop.to_byte_array())
	return data


#func _draw() -> void:
	#for x in positions:
		#draw_circle(x, radius, Color.BLUE)

func _process(delta: float) -> void:
	pass

var timings = {}
func debug_sim_step(delta):
	if not rd: return
	
	var global_size = (count / shader_local_size) + 1
	var hash_size = ((count * hash_oversizing) / shader_local_size) + 1
	var params = [0, radius, smoothing_radius, gravity, default_density, pressure_multiply, damping, count, count * hash_oversizing, mass, delta, length, width, height, viscosity_multiplier, 0, 0, 0, 0, 0]
	
	timings.clear()
	var total_start = Time.get_ticks_usec()

	var run_stage = func(stage_name: String, g_size: int, p_array: Array, pipe: RID, u_set: RID):
		var s_start = Time.get_ticks_usec()
		var list = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipe)
		rd.compute_list_bind_uniform_set(list, u_set, 0)
		var d = params_to_byte_array(p_array)
		rd.compute_list_set_push_constant(list, d, d.size())
		rd.compute_list_dispatch(list, g_size, 1, 1)
		rd.compute_list_end()
		
		rd.submit()
		rd.sync()
		timings[stage_name] = Time.get_ticks_usec() - s_start


	# Case 0: Очистка буфера хеша
	params[0] = 0 
	run_stage.call("Clear Hash", hash_size, params, pipeline, uniform_set)

	# Case 1: Предсказание позиций и подсчет частиц в ячейках
	params[0] = 1 
	run_stage.call("Predict & Fill Count", global_size, params, pipeline, uniform_set)

	var sum_start = Time.get_ticks_usec()
	
	#var list = rd.compute_list_begin()
	#rd.compute_list_bind_compute_pipeline(list, sum_pipeline)
	#rd.compute_list_bind_uniform_set(list, sum_uniform_set, 0)
	#
	#var sum_groups = (count_sqrt / shader_local_size) + 1
	#
	#var data = params_to_byte_array([count_sqrt, 0, 0, 0])
	#rd.compute_list_set_push_constant(list, data, data.size())
	#rd.compute_list_dispatch(list, sum_groups, 1, 1)
	#rd.compute_list_add_barrier(list)
	#
	#data = params_to_byte_array([count_sqrt, 1, 0, 0])
	#rd.compute_list_set_push_constant(list, data, data.size())
	#rd.compute_list_dispatch(list, sum_groups, 1, 1)
	#rd.compute_list_add_barrier(list)
	#
	#rd.compute_list_end()
	#rd.submit()
	#rd.sync()
	
	timings["Prefix Sum"] = Time.get_ticks_usec() - sum_start

	# Case 2: Сортировка (заполнение индексов хеша)
	params[0] = 2 
	run_stage.call("Fill Hash Indexes", global_size, params, pipeline, uniform_set)

	# Case 4: Расчет плотности (Density)
	params[0] = 4 
	run_stage.call("Compute Density", global_size, params, pipeline, uniform_set)

	# Case 5: Расчет сил (Forces)
	params[0] = 5 
	run_stage.call("Compute Forces", global_size, params, pipeline, uniform_set)

	# Case 6: Финальная коррекция и вывод в MultiMesh
	params[0] = 6 
	run_stage.call("Correct & Draw", global_size, params, pipeline, uniform_set)

	var total_time = Time.get_ticks_usec() - total_start
	_print_results(total_time)

func _print_results(total):
	print("\n--- GPU PROFILER (Local Device) ---")
	print("Total Frame: %.3f ms" % (total / 1000.0))
	for stage in timings:
		var ms = timings[stage] / 1000.0
		var p = (timings[stage] / float(total)) * 100.0
		print("%-15s: %6.3f ms (%4.1f%%)" % [stage, ms, p])

func sim_step(delta):
	if profiler_mode:
		debug_sim_step(delta)
		return
	
	#var positions = Utility.float_byte_array_to_Vector3Array(rd.buffer_get_data(positions_buffer))
	#print(positions)
	#print(Utility.get_PackedFloat32Array(rd.buffer_get_data(density_buffer)))
	
	var global_size = (count/shader_local_size)+1
	var hash_size = ((count * hash_oversizing) / shader_local_size) + 1
	
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	var data
	# shader PUSH CONSTANT params
	var params = [0, radius, smoothing_radius, gravity, default_density, pressure_multiply, damping, count, count * hash_oversizing, mass, delta, length, width, height, viscosity_multiplier, 0, 0, 0, 0, 0]
	
	#params[0] = -1
	#data = params_to_byte_array(params)
	#rd.compute_list_set_push_constant(compute_list, data, data.size())
	#rd.compute_list_dispatch(compute_list, hash_size, 1, 1)	
	#
	#params[0] = 3
	#data = params_to_byte_array(params)
	#rd.compute_list_set_push_constant(compute_list, data, data.size())
	#rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	
	params[0] = 0
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, hash_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)
	
	params[0] = 1
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)
	
	rd.compute_list_bind_compute_pipeline(compute_list, sum_pipeline)
	var step = 1
	var ln = count * hash_oversizing * 2
	var i = 1
	while step < ln:
		if i % 2:
			rd.compute_list_bind_uniform_set(compute_list, first_step_sum_uniform_set, 0)
		else:
			rd.compute_list_bind_uniform_set(compute_list, second_step_sum_uniform_set, 0)
		i += 1
		data = params_to_byte_array([step, 0, 0, 0])
		rd.compute_list_set_push_constant(compute_list, data , data.size())
		rd.compute_list_dispatch(compute_list, hash_size, 1, 1)
		rd.compute_list_add_barrier(compute_list)
		step *= 2
	
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	params[0] = 2
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)
	
	params[0] = 4
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)
	
	params[0] = 5
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)
	
	params[0] = 6
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)
	
	rd.compute_list_end()
	#rd.submit()
	#rd.sync()
	#
	#var image = Image.create_from_data(img_size_x, img_size_y, false, Image.FORMAT_RGBAF, rd.texture_get_data(output_tex, 0))
	#
	#%TextureRect.texture.update(image)
	
	#queue_redraw()
	

func get_buffer_uniform(binding, buffer) -> RDUniform:
	var unif := RDUniform.new()
	unif.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	unif.binding = binding
	unif.add_id(buffer)
	return unif

func set_multimesh_aabb():
	var mm = %MultiMeshInstance3D
	if is_instance_valid(mm.multimesh):
		var aabb = AABB(mm.global_position, Vector3(length, height, width))
		mm.multimesh.custom_aabb = aabb

func rebuild_buffers():
	if not has_node("%MultiMeshInstance3D"):
		return
	
	var mm = MultiMesh.new()
	mm.use_colors = true
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = count
	var aabb = AABB(%MultiMeshInstance3D.global_position, Vector3(length * 8, height * 8, width * 8))
	mm.custom_aabb = aabb
	for i in range(count):
		var t := Transform3D()
		mm.set_instance_transform(i, t)

	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = 2 * radius
	sphere.radial_segments = 12
	sphere.rings = 6
	
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true 
	
	var outline_mat := StandardMaterial3D.new()
	outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED 
	outline_mat.albedo_color = Color.BLACK                        
	outline_mat.cull_mode = BaseMaterial3D.CULL_FRONT            
	outline_mat.grow = true                                        
	outline_mat.grow_amount = 0.007 / 8                       
	
	mat.next_pass = outline_mat
	
	sphere.material = mat
	mm.mesh = sphere
	
	%MultiMeshInstance3D.multimesh = mm
	
	
	var mm_rid = RenderingServer.multimesh_get_buffer_rd_rid(mm.get_rid())
	
	
	# load and begin compiling compute shader
	var shader_file :RDShaderFile= load("uid://blbluf43jc54l")
	var shader_spirv :RDShaderSPIRV= shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	pipeline = rd.compute_pipeline_create(shader)
	
	var pref_sum: RDShaderFile = load("uid://b7u0trucvfk1p")
	var shader_pref_spirv: RDShaderSPIRV = pref_sum.get_spirv()
	sum_shader = rd.shader_create_from_spirv(shader_pref_spirv)
	sum_pipeline = rd.compute_pipeline_create(sum_shader)
	#var arr: PackedInt32Array
	#for i in range(hash_oversizing * positions.size()):
		#arr.append(i)

	pref_sum_hash_count_buffer = rd.storage_buffer_create(int_size * hash_oversizing * positions.size())
	pref_sum_hash_count_buffer2 = rd.storage_buffer_create(int_size * hash_oversizing * positions.size())
	
	var unif1 := get_buffer_uniform(0, pref_sum_hash_count_buffer)
	var unif2 := get_buffer_uniform(1, pref_sum_hash_count_buffer2)
	first_step_sum_uniform_set = rd.uniform_set_create([unif1, unif2], sum_shader, 0)
	
	unif1.binding = 1
	unif2.binding = 0
	second_step_sum_uniform_set = rd.uniform_set_create([unif1, unif2], sum_shader, 0)
	#print(positions)
	var data = positions.to_byte_array()
	positions_buffer = rd.storage_buffer_create(data.size(), data)
	predicated_positions_buffer = rd.storage_buffer_create(data.size())
	velocity_buffer = rd.storage_buffer_create(data.size())
	density_buffer = rd.storage_buffer_create(int_size * positions.size())
	hash_count_buffer = rd.storage_buffer_create(int_size * hash_oversizing * positions.size())
	hash_indexes_buffer = rd.storage_buffer_create(int_size * positions.size())
	force_buffer = rd.storage_buffer_create(data.size())
	
	#var output_image := Image.create(img_size_x, img_size_y, false, Image.FORMAT_RGBAF)
	#var image_texture := ImageTexture.create_from_image(output_image)
	#%TextureRect.texture = image_texture
	#output_tex = rd.texture_create(fmt, view)
	
	#var texture := Texture2DRD.new()
	#texture.texture_rd_rid = output_tex
	#%TextureRect.texture = texture
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	var sampler_rid : RID = rd.sampler_create(sampler_state)
	
	var sdf_uniform := RDUniform.new()
	sdf_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	sdf_uniform.binding = 11
	
	sdf_uniform.add_id(sampler_rid)
	sdf_uniform.add_id(RenderingServer.texture_get_rd_texture(%GPUParticlesCollisionSDF3D.texture.get_rid()))
	
	positions_uniform                = get_buffer_uniform(0, positions_buffer)
	predicated_positions_uniform     = get_buffer_uniform(1, predicated_positions_buffer)
	velocity_uniform                 = get_buffer_uniform(2, velocity_buffer)
	density_uniform                  = get_buffer_uniform(3, density_buffer)
	hash_count_uniform               = get_buffer_uniform(4, hash_count_buffer)
	pref_sum_hash_count_uniform      = get_buffer_uniform(5, pref_sum_hash_count_buffer)
	hash_indexes_uniform             = get_buffer_uniform(6, hash_indexes_buffer)
	pref_sum_hash_count_uniform2      = get_buffer_uniform(7, pref_sum_hash_count_buffer2)
	force_buffer_uniform = get_buffer_uniform(9, force_buffer)
	var mm_uniform = get_buffer_uniform(10, mm_rid)
	
	#output_tex_uniform = RDUniform.new()
	#output_tex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	#output_tex_uniform.binding = 8
	#output_tex_uniform.add_id(output_tex)
	
	if profiler_mode:
		var dummy_mm_buffer = rd.storage_buffer_create(count * 128) # Примерный размер
		mm_uniform = get_buffer_uniform(10, dummy_mm_buffer)
		
		var fmt := RDTextureFormat.new()
		fmt.width = 8
		fmt.height = 8
		fmt.depth = 8
		fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT 
		fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
		fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT

		var dummy_sdf_tex = rd.texture_create(fmt, RDTextureView.new())

		sampler_state = RDSamplerState.new()
		sampler_rid = rd.sampler_create(sampler_state)

		sdf_uniform = RDUniform.new()
		sdf_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		sdf_uniform.binding = 11
		sdf_uniform.add_id(sampler_rid)  
		sdf_uniform.add_id(dummy_sdf_tex)
	
	uniform_set = rd.uniform_set_create([positions_uniform, 
	predicated_positions_uniform, 
	velocity_uniform, 
	density_uniform, 
	hash_count_uniform, 
	pref_sum_hash_count_uniform, 
	hash_indexes_uniform, 
	#output_tex_uniform, 
	pref_sum_hash_count_uniform2, 
	force_buffer_uniform,
	mm_uniform,
	sdf_uniform,
	], shader, 0)
	
	

@export_tool_button("Rebuild")
var rebuild := rebuild_buffers
