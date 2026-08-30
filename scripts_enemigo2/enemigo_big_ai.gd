extends CharacterBody3D

enum State { IDLE, CHASE, ATTACK, HURT, DEAD }

@export var max_hp: int = 120
@export var move_speed: float = 4.5
@export var walk_speed: float = 2.3
@export var attack_range: float = 2.2
@export var damage: int = 18

@export var attack_cooldown: float = 1.15
@export var rotation_speed: float = 10.0
@export var walking_distance_from_target: float = 2.0
@export var model_forward_yaw_offset: float = PI
@export var hit_freeze_time: float = 0.12
@export var hitstun_time: float = 0.35

@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D
@onready var animation_player: AnimationPlayer = get_node_or_null("AnimationPlayer") as AnimationPlayer
@onready var detection_area: Area3D = $DetectionArea
@onready var hitbox: Area3D = $Hitbox
@onready var hurtbox: Area3D = $Hurtbox

var state: State = State.IDLE
var hp: int
var target_player: Node3D = null

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _rng := RandomNumberGenerator.new()
var _idle_swap_timer: float = 0.0
var _last_idle_animation: StringName = &"idle_2"

var _attack_cooldown_timer: float = 0.0
var _is_attacking: bool = false
var _next_attack_index: int = 0
var _attack_animations: Array[StringName] = [&"attack01", &"punch"]
var _hit_targets: Array[Node3D] = []

var _hit_freeze_timer: float = 0.0
var _hitstun_timer: float = 0.0


func _ready() -> void:
	if animation_player == null:
		animation_player = get_node_or_null("Enemigobig/AnimationPlayer") as AnimationPlayer
	
	if animation_player == null:
		push_error("EnemigoBigAI: no se encontro AnimationPlayer.")
		set_physics_process(false)
		return
	
	_configure_animation_loops()
	hp = max_hp
	_rng.randomize()
	_disable_hitbox()
	
	detection_area.body_entered.connect(_on_detection_area_body_entered)
	detection_area.body_exited.connect(_on_detection_area_body_exited)
	hitbox.body_entered.connect(_on_hitbox_body_entered)
	hurtbox.area_entered.connect(_on_hurtbox_area_entered)
	animation_player.animation_finished.connect(_on_animation_finished)
	
	_change_state(State.IDLE)


func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return
	
	_attack_cooldown_timer = maxf(_attack_cooldown_timer - delta, 0.0)
	
	if not _has_valid_target():
		_refresh_target_from_detection_area()
	
	if not _has_valid_target() and state != State.HURT:
		target_player = null
		if state != State.IDLE:
			_change_state(State.IDLE)
	
	match state:
		State.IDLE:
			_state_idle(delta)
		State.CHASE:
			_state_chase(delta)
		State.ATTACK:
			_state_attack(delta)
		State.HURT:
			_state_hurt(delta)


func take_damage(amount: int) -> void:
	if state == State.DEAD or amount <= 0:
		return
	
	hp = maxi(hp - amount, 0)
	velocity = Vector3.ZERO
	_is_attacking = false
	_disable_hitbox()
	
	if hp <= 0:
		_change_state(State.DEAD)
		return
	
	# Interrumpe la accion actual y congela brevemente la pose para simular impacto.
	_hit_freeze_timer = hit_freeze_time
	_hitstun_timer = hitstun_time
	_set_animation_paused(true)
	_change_state(State.HURT)


func _state_idle(delta: float) -> void:
	if _has_valid_target():
		_change_state(State.CHASE)
		return
	
	_idle_swap_timer -= delta
	if _idle_swap_timer <= 0.0:
		_play_random_idle()
	
	_stop_horizontal_motion()
	_apply_gravity(delta)
	move_and_slide()


func _state_chase(delta: float) -> void:
	if not _has_valid_target():
		_change_state(State.IDLE)
		return
	
	var target_distance: float = _distance_to_target()
	if target_distance <= attack_range:
		_change_state(State.ATTACK)
		return
	
	navigation_agent.target_position = target_player.global_position
	var next_path_position: Vector3 = navigation_agent.get_next_path_position()
	var direction: Vector3 = _get_flat_direction_to(next_path_position)
	if direction.length_squared() <= 0.001:
		direction = _get_flat_direction_to(target_player.global_position)
	
	if direction.length_squared() > 0.001:
		direction = direction.normalized()
		_face_direction(direction, delta)
		var desired_speed: float = _get_chase_speed(target_distance)
		velocity.x = direction.x * desired_speed
		velocity.z = direction.z * desired_speed
	else:
		_stop_horizontal_motion()
	
	_apply_gravity(delta)
	_play_locomotion_animation(target_distance)
	move_and_slide()


func _state_attack(delta: float) -> void:
	if not _has_valid_target():
		_change_state(State.IDLE)
		return
	
	if _distance_to_target() > attack_range:
		_change_state(State.CHASE)
		return
	
	_stop_horizontal_motion()
	_face_position(target_player.global_position, delta)
	_apply_gravity(delta)
	move_and_slide()
	
	if not _is_attacking and _attack_cooldown_timer <= 0.0:
		_start_attack()


func _state_hurt(delta: float) -> void:
	_stop_horizontal_motion()
	_apply_gravity(delta)
	move_and_slide()
	
	if _hit_freeze_timer > 0.0:
		_hit_freeze_timer -= delta
		if _hit_freeze_timer <= 0.0:
			_set_animation_paused(false)
			_play_animation(&"idle")
	
	_hitstun_timer -= delta
	if _hitstun_timer <= 0.0:
		if _has_valid_target():
			_change_state(State.CHASE)
		else:
			_change_state(State.IDLE)


func _start_attack() -> void:
	_is_attacking = true
	_hit_targets.clear()
	_disable_hitbox()
	
	var attack_animation: StringName = _attack_animations[_next_attack_index]
	_next_attack_index = (_next_attack_index + 1) % _attack_animations.size()
	_attack_cooldown_timer = attack_cooldown
	_play_animation(attack_animation, 0.05)


# Llamar desde Animation Call Method Tracks en los frames activos del golpe.
func _enable_hitbox() -> void:
	if state != State.ATTACK or not _is_attacking:
		return
	_set_area_enabled(hitbox, true)


# Llamar desde Animation Call Method Tracks al terminar la ventana de impacto.
func _disable_hitbox() -> void:
	_set_area_enabled(hitbox, false)


func _change_state(new_state: State) -> void:
	if state == State.DEAD:
		return
	
	if state == State.ATTACK and new_state != State.ATTACK:
		_is_attacking = false
		_disable_hitbox()
	
	state = new_state
	
	match state:
		State.IDLE:
			_set_animation_paused(false)
			_reset_idle_timer()
			_stop_horizontal_motion()
		State.CHASE:
			_set_animation_paused(false)
			_disable_hitbox()
		State.ATTACK:
			_set_animation_paused(false)
			_stop_horizontal_motion()
			_disable_hitbox()
		State.HURT:
			_stop_horizontal_motion()
			_disable_hitbox()
		State.DEAD:
			_die()


func _die() -> void:
	state = State.DEAD
	target_player = null
	velocity = Vector3.ZERO
	_set_animation_paused(false)
	
	collision_layer = 0
	collision_mask = 0
	collision_shape.set_deferred("disabled", true)
	_set_area_enabled(detection_area, false)
	_set_area_enabled(hitbox, false)
	_set_area_enabled(hurtbox, false)
	
	if animation_player.has_animation(&"dead"):
		animation_player.play(&"dead")
	else:
		queue_free()


func _play_random_idle() -> void:
	var next_idle: StringName = &"idle"
	if _last_idle_animation == &"idle":
		next_idle = &"idle_2"
	elif _rng.randf() < 0.5:
		next_idle = &"idle_2"
	
	_last_idle_animation = next_idle
	_play_animation(next_idle, 0.15)
	_reset_idle_timer()


func _reset_idle_timer() -> void:
	_idle_swap_timer = _rng.randf_range(2.0, 4.0)


func _play_animation(animation_name: StringName, blend: float = 0.1) -> void:
	if not animation_player.has_animation(animation_name):
		push_warning("EnemigoBigAI: falta la animacion '%s'." % animation_name)
		return
	
	if animation_player.current_animation == animation_name and animation_player.is_playing():
		return
	
	animation_player.play(animation_name, blend)


func _configure_animation_loops() -> void:
	for animation_name: StringName in [&"idle", &"idle_2", &"run", &"walking"]:
		if animation_player.has_animation(animation_name):
			animation_player.get_animation(animation_name).loop_mode = Animation.LOOP_LINEAR
	
	for animation_name: StringName in [&"attack01", &"punch", &"dead", &"T_pose"]:
		if animation_player.has_animation(animation_name):
			animation_player.get_animation(animation_name).loop_mode = Animation.LOOP_NONE


func _get_chase_speed(target_distance: float) -> float:
	if target_distance <= attack_range + walking_distance_from_target:
		return walk_speed
	return move_speed


func _play_locomotion_animation(target_distance: float) -> void:
	if target_distance <= attack_range + walking_distance_from_target and animation_player.has_animation(&"walking"):
		_play_animation(&"walking")
	elif animation_player.has_animation(&"run"):
		_play_animation(&"run")
	else:
		_play_animation(&"walking")


func _set_animation_paused(paused: bool) -> void:
	animation_player.speed_scale = 0.0 if paused else 1.0


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0.0


func _stop_horizontal_motion() -> void:
	velocity.x = 0.0
	velocity.z = 0.0


func _face_direction(direction: Vector3, delta: float) -> void:
	if direction.length_squared() <= 0.001:
		return
	var target_yaw: float = atan2(-direction.x, -direction.z) + model_forward_yaw_offset
	var turn_weight: float = clampf(rotation_speed * delta, 0.0, 1.0)
	rotation.y = lerp_angle(rotation.y, target_yaw, turn_weight)


func _face_position(world_position: Vector3, delta: float) -> void:
	_face_direction(_get_flat_direction_to(world_position), delta)


func _get_flat_direction_to(world_position: Vector3) -> Vector3:
	var direction: Vector3 = world_position - global_position
	direction.y = 0.0
	return direction


func _distance_to_target() -> float:
	if not _has_valid_target():
		return INF
	return global_position.distance_to(target_player.global_position)


func _has_valid_target() -> bool:
	return is_instance_valid(target_player) and target_player.is_inside_tree()


func _refresh_target_from_detection_area() -> void:
	for body: Node3D in detection_area.get_overlapping_bodies():
		if body.is_in_group("player"):
			target_player = body
			return


func _set_area_enabled(area: Area3D, enabled: bool) -> void:
	area.set_deferred("monitoring", enabled)
	area.set_deferred("monitorable", enabled)
	for child: Node in area.get_children():
		if child is CollisionShape3D:
			(child as CollisionShape3D).set_deferred("disabled", not enabled)


func _on_detection_area_body_entered(body: Node3D) -> void:
	if state == State.DEAD:
		return
	
	if body.is_in_group("player"):
		target_player = body
		if state != State.HURT:
			_change_state(State.CHASE)


func _on_detection_area_body_exited(body: Node3D) -> void:
	if body == target_player:
		target_player = null
		if state != State.HURT and state != State.DEAD:
			_change_state(State.IDLE)


func _on_hitbox_body_entered(body: Node3D) -> void:
	if state != State.ATTACK or not _is_attacking:
		return
	
	if not body.is_in_group("player") or _hit_targets.has(body):
		return
	
	_hit_targets.append(body)
	if body.has_method("take_damage"):
		body.call("take_damage", damage)
	elif body.has_method("apply_damage"):
		body.call("apply_damage", damage)


func _on_hurtbox_area_entered(area: Area3D) -> void:
	if state == State.DEAD or area == hitbox or area.owner == self:
		return
	
	var attacker: Node = area.owner if area.owner != null else area.get_parent()
	var comes_from_player: bool = area.is_in_group("player_attack") or (
		attacker != null and attacker.is_in_group("player")
	)
	
	if not comes_from_player:
		return
	
	if area.has_meta("damage"):
		take_damage(int(area.get_meta("damage")))
	elif area.has_method("get_damage"):
		take_damage(int(area.call("get_damage")))
	elif attacker != null and attacker.has_method("get_damage"):
		take_damage(int(attacker.call("get_damage")))


func _on_animation_finished(animation_name: StringName) -> void:
	if state == State.DEAD and animation_name == &"dead":
		queue_free()
		return
	
	if _attack_animations.has(animation_name):
		_is_attacking = false
		_disable_hitbox()
