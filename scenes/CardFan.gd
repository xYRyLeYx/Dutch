class_name CardFan
extends Container
## CardFan.gd
## Coloca cartas en abanico en vez de en fila.
##
## Existe por un motivo muy concreto: la mano crece (cada quemada fallida te
## da una carta más) y un HBoxContainer con cartas de ancho fijo se sale de la
## pantalla en cuanto tienes 6 o 7. Aquí las cartas se van solapando cuanto
## más mano tengas, así que la mano SIEMPRE cabe, y de paso quedan en arco
## como si las sujetaras.

@export var card_size := Vector2(70, 100)
@export var gap: float = 10.0          # separación cuando sobra sitio
@export var max_angle_deg: float = 0.0 # apertura total del abanico
@export var arc_lift: float = 0.0      # cuánto sube la carta central
@export var min_visible: float = 0.34  # fracción mínima visible de cada carta

func _get_minimum_size() -> Vector2:
	return Vector2(card_size.x, card_size.y + arc_lift + max_angle_deg * 0.35)

func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		_layout()

func set_card_size(s: Vector2) -> void:
	card_size = s
	update_minimum_size()
	queue_sort()

func _layout() -> void:
	var kids: Array[Control] = []
	for c in get_children():
		if c is Control and c.visible:
			kids.append(c)
	var n := kids.size()
	if n == 0:
		return

	var step := card_size.x + gap
	if n > 1:
		var needed := card_size.x + step * (n - 1)
		if needed > size.x:
			step = max((size.x - card_size.x) / float(n - 1), card_size.x * min_visible)
	var total := card_size.x + step * (n - 1)
	var x0 := (size.x - total) * 0.5

	for i in range(n):
		var child := kids[i]
		# -1 en el extremo izquierdo, +1 en el derecho.
		var f: float = 0.0 if n == 1 else (float(i) / float(n - 1) - 0.5) * 2.0
		var lift: float = (1.0 - f * f) * arc_lift
		child.pivot_offset = Vector2(card_size.x * 0.5, card_size.y * 1.5)
		child.rotation = deg_to_rad(f * max_angle_deg * 0.5)
		fit_child_in_rect(child, Rect2(
			Vector2(x0 + step * i, arc_lift - lift),
			card_size))
