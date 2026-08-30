extends Node


func _enable_hitbox() -> void:
	var enemy_root := get_parent()
	if enemy_root != null and enemy_root.has_method("_enable_hitbox"):
		enemy_root.call("_enable_hitbox")


func _disable_hitbox() -> void:
	var enemy_root := get_parent()
	if enemy_root != null and enemy_root.has_method("_disable_hitbox"):
		enemy_root.call("_disable_hitbox")
