class_name RulesScreen
extends Control
## RulesScreen.gd
## Las reglas en texto, una sección por página, con flechas para pasarlas.
## Pensado para leer con calma o para consultar un punto concreto: el que
## quiera aprender jugando tiene el tutorial guiado (TutorialOverlay).
##
## Se añade como hijo directo de Main y se destruye sola al cerrarse — no
## depende de modal_layer ni de fx_layer, así que puede abrirse desde
## cualquier pantalla (incluida una partida en curso) sin pelearse con los
## modales del juego.

signal closed

## Cada sección: título, líneas cortas (una idea por línea, nada de párrafos
## largos) y opcionalmente un par de cartas reales que ilustran la regla —
## enseñarlo con las cartas del propio juego vale más que describirlo.
class Section:
	var title: String
	var lines: Array
	var cards: Array
	func _init(t: String, l: Array, c: Array = []) -> void:
		title = t
		lines = l
		cards = c

const CARD_SIZE := Vector2(80, 112)

var _sections: Array = []
var _page: int = 0

var _stage: VBoxContainer
var _dots: HBoxContainer
var _prev_btn: Button
var _next_btn: Button

func setup() -> void:
	_build_sections()
	_build_ui()

func _build_sections() -> void:
	_sections = [
		Section.new("Objetivo",
			["Cada jugador empieza con 4 cartas boca abajo.",
			"Gana quien menos sume cuando termina la partida:",
			"cuanto más bajas tus cartas, mejor para ti."]),
		Section.new("Mira tus cartas",
			["Al empezar, miras 2 de tus 4 cartas y las memorizas.",
			"Después se vuelven a tapar: no podrás volver a",
			"mirarlas en el resto de la partida."]),
		Section.new("Tu turno",
			["Robas una carta del mazo o del descarte.",
			"Si te sirve, la cambias por una de tu mano:",
			"la vieja va al descarte, boca arriba.",
			"Si no te sirve, la descartas directamente."]),
		Section.new("Quemar cartas",
			["En cualquier momento, cualquiera puede descartar una",
			"carta de su mano con el MISMO NÚMERO que la de arriba",
			"del descarte, sin esperar su turno.",
			"Si te equivocas de número, te llevas una carta de",
			"penalización.",
			"Una carta quemada ya no se puede robar del descarte."],
			["oros-7", "copas-7"]),
		Section.new("Cartas especiales: 10 y 11",
			["El 10 deja mirar una carta de tu propia mano.",
			"El 11 obliga a un intercambio a ciegas: tú te llevas",
			"una carta suya y él una tuya, sin que ninguno vea",
			"cuál le han quitado."],
			["espadas-10", "bastos-11"]),
		Section.new("El 12: la carta rara",
			["El 12 de espadas y el de oros valen 0 puntos.",
			"El 12 de bastos y el de copas valen 30 puntos.",
			"El resto de cartas vale su propio número."],
			["oros-12", "copas-12"]),
		Section.new("Decir \"Dutch\"",
			["A partir de la ronda 4, al empezar tu turno puedes",
			"cantar \"Dutch\" en vez de robar. Juegas ese turno con",
			"normalidad y se da una última vuelta a los demás.",
			"Al volver a ti, la partida termina y se cuentan los",
			"puntos: gana quien menos sume."]),
	]

## ---------- ESTRUCTURA ----------

func _build_ui() -> void:
	# ..._and_offsets_preset y NO set_anchors_preset: éste último conserva el
	# rectángulo actual, y al llamarse después de add_child (con el nodo aún a
	# 0x0) la pantalla se quedaría de tamaño cero.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	modulate = Color(1, 1, 1, 0)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.86)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 36)
	margin.add_theme_constant_override("margin_right", 36)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	add_child(margin)

	var panel := DutchUI.panel(true)
	margin.add_child(panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	panel.add_child(outer)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	outer.add_child(head)
	head.add_child(DutchUI.title("Reglas del juego", 24))
	var head_spacer := Control.new()
	head_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(head_spacer)
	var close_btn := DutchUI.button("Cerrar", _close)
	close_btn.custom_minimum_size = Vector2(100, 40)
	head.add_child(close_btn)

	_stage = VBoxContainer.new()
	_stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stage.alignment = BoxContainer.ALIGNMENT_CENTER
	_stage.add_theme_constant_override("separation", 12)
	outer.add_child(_stage)

	_dots = HBoxContainer.new()
	_dots.alignment = BoxContainer.ALIGNMENT_CENTER
	_dots.add_theme_constant_override("separation", 6)
	outer.add_child(_dots)

	var nav := HBoxContainer.new()
	nav.alignment = BoxContainer.ALIGNMENT_CENTER
	nav.add_theme_constant_override("separation", 12)
	outer.add_child(nav)
	_prev_btn = DutchUI.button("< Anterior", func(): _go(_page - 1))
	_prev_btn.custom_minimum_size = Vector2(160, 46)
	nav.add_child(_prev_btn)
	_next_btn = DutchUI.button("Siguiente >", _on_next, "primary")
	_next_btn.custom_minimum_size = Vector2(200, 46)
	nav.add_child(_next_btn)

	_render_page()

	# Entrada suave: el resto del juego siempre anuncia sus pantallas con una
	# transición, y una superposición que aparece de golpe desentonaría.
	create_tween().tween_property(self, "modulate", Color(1, 1, 1, 1), 0.18)

func _close() -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate", Color(1, 1, 1, 0), 0.14)
	tw.tween_callback(func():
		closed.emit()
		queue_free()
	)

func _on_next() -> void:
	if _page >= _sections.size() - 1:
		_close()
	else:
		_go(_page + 1)

func _go(p: int) -> void:
	if p < 0 or p >= _sections.size():
		return
	_page = p
	_render_page()

func _render_page() -> void:
	for c in _stage.get_children():
		_stage.remove_child(c)
		c.queue_free()
	for c in _dots.get_children():
		_dots.remove_child(c)
		c.queue_free()

	var sec: Section = _sections[_page]
	_stage.add_child(DutchUI.label("Regla %d de %d" % [_page + 1, _sections.size()], 12, DutchUI.TEXT_MUTED, true))
	_stage.add_child(DutchUI.title(sec.title, 22, DutchUI.GOLD))

	var body := VBoxContainer.new()
	body.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_theme_constant_override("separation", 2)
	_stage.add_child(body)
	for line in sec.lines:
		body.add_child(DutchUI.label(str(line), 15, DutchUI.TEXT, true))

	if sec.cards.size() > 0:
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 16)
		_stage.add_child(row)
		for cid in sec.cards:
			var cv := CardView.new()
			cv.custom_minimum_size = CARD_SIZE
			cv.pivot_offset = CARD_SIZE * 0.5
			cv.set_interactive(false)
			cv.set_card(str(cid), true)
			row.add_child(cv)

	for i in range(_sections.size()):
		var dot := PanelContainer.new()
		var on: bool = i == _page
		var sb := DutchUI.box(DutchUI.GOLD if on else Color(DutchUI.PANEL_BORDER, 0.5),
			DutchUI.GOLD_DARK if on else Color(DutchUI.PANEL_BORDER, 0.5), 1)
		sb.content_margin_top = 0
		sb.content_margin_bottom = 0
		sb.content_margin_left = 0
		sb.content_margin_right = 0
		dot.add_theme_stylebox_override("panel", sb)
		dot.custom_minimum_size = Vector2(10, 10)
		_dots.add_child(dot)

	_prev_btn.disabled = _page == 0
	_next_btn.text = "Cerrar" if _page == _sections.size() - 1 else "Siguiente >"
