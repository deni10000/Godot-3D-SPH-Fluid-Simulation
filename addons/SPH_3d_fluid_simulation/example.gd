extends Node3D

var fps:
	set(value):
		%Fps.text = str(1 / value)

@export
var simulate: bool = false

@onready
var simulation = $FluidSimulation


func _ready() -> void:
	%ViscositySpinBox.value = simulation.viscosity_multiplier
	%SpinBox.value = simulation.count
	%SpacingSpinBox.value = simulation.radius
	%SmoothingSpinBox.value = simulation.smoothing_radius
	%DensitySpinBox.value = simulation.default_density
	%SpinBox2.value = simulation.pressure_multiply
	%GravitySpinBox.value = simulation.gravity
	%MassSpinBox.value = simulation.mass
	
	#simulation.count = 50000
	if Engine.is_editor_hint():
		return
	get_tree().paused = true

var start = Time.get_ticks_usec()
var counter = 0;
func _physics_process(delta: float) -> void:
	#if Engine.is_editor_hint():
		#return
	fps = delta
	if not(simulate or not Engine.is_editor_hint()):
		return
	simulation.sim_step(delta)
	#counter += 1
	#if counter == 5000:
		#var end = Time.get_ticks_usec()
		#print((end - start) / 1e6 / 3000)
	


func _on_spin_box_value_changed(value: float) -> void:
	simulation.count = value


func _on_spacing_spin_box_value_changed(value: float) -> void:
	simulation.radius = value


func _on_pause_button_pressed() -> void:
	get_tree().paused = not get_tree().paused

func _on_smoothing_spin_box_value_changed(value: float) -> void:
	simulation.smoothing_radius = value


func _on_density_spin_box_value_changed(value: float) -> void:
	simulation.default_density = value


func _on_next_step_button_pressed() -> void:
	if get_tree().paused:
		simulation.sim_step(0.01)


func _on_spin_box_2_value_changed(value: float) -> void:
	simulation.pressure_multiply = value


func _on_gravity_spin_box_value_changed(value: float) -> void:
	simulation.gravity = value


func _on_mass_spin_box_value_changed(value: float) -> void:
	simulation.mass = value


func _on_viscosity_spin_box_value_changed(value: float) -> void:
	simulation.viscosity_multiplier = value
