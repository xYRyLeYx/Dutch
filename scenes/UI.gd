class_name DutchUI
extends RefCounted
## UI.gd — el lenguaje visual del juego: taberna medieval en pixel art.
##
## Todo es cuadrado a propósito. En pixel art las esquinas redondeadas y los
## degradados delatan al motor, así que los paneles son marcos de 2 px, las
## sombras son duras y las tipografías van con el suavizado APAGADO.

## ---------- PALETA ----------

const PANEL := Color("#3a2416")
const PANEL_HI := Color("#4d3220")
const PANEL_DEEP := Color("#241610")
const PANEL_BORDER := Color("#7a5433")

const GOLD := Color("#e8b84b")
const GOLD_DARK := Color("#9a6b1e")

const TEXT := Color("#f2e2c4")
const TEXT_MUTED := Color("#b39a78")
const TEXT_DARK := Color("#241610")

const EMBER := Color("#ff8c3a")
const DANGER := Color("#c2494b")

static func suit_color(suit: String) -> Color:
	return PixelArt.suit_main(suit)

## ---------- TIPOGRAFÍA ----------
##
## Si dejas un .ttf en res://assets/fonts/pixel.ttf (por ejemplo "Press Start
## 2P" o cualquier fuente de mapa de bits), el juego lo usa automáticamente y
## el conjunto queda redondo. Si no, se recurre a una fuente del sistema con
## el suavizado desactivado, que es lo más parecido que hay sin añadir
## archivos al proyecto.

const PIXEL_FONT_PATH := "res://assets/fonts/pixel.ttf"

static var _display_font: Font = null
static var _body_font: Font = null

static func _hard_edges(f: Font) -> Font:
	# Las propiedades se comprueban antes de asignarlas: cambian de nombre
	# entre versiones de Godot y una propiedad inexistente es un error, no un
	# aviso.
	if "antialiasing" in f:
		f.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	if "subpixel_positioning" in f:
		f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	if "hinting" in f:
		f.hinting = TextServer.HINTING_NONE
	return f

static func _custom_pixel_font() -> Font:
	if not ResourceLoader.exists(PIXEL_FONT_PATH):
		return null
	var res := load(PIXEL_FONT_PATH)
	if res is Font:
		return _hard_edges(res)
	return null

static func display() -> Font:
	if _display_font == null:
		var custom := _custom_pixel_font()
		if custom != null:
			_display_font = custom
		else:
			var f := SystemFont.new()
			# Familias anchas y de trazo recto: son las que menos desentonan
			# junto a un dibujo de píxeles.
			f.font_names = PackedStringArray([
				"Consolas", "Lucida Console", "Courier New",
				"DejaVu Sans Mono", "Roboto Mono", "monospace",
			])
			if "font_weight" in f:
				f.font_weight = 700
			if "allow_system_fallback" in f:
				f.allow_system_fallback = true
			_display_font = _hard_edges(f)
	return _display_font

static func body() -> Font:
	if _body_font == null:
		var custom := _custom_pixel_font()
		if custom != null:
			_body_font = custom
		else:
			var f := SystemFont.new()
			f.font_names = PackedStringArray([
				"Segoe UI", "Roboto", "Noto Sans", "DejaVu Sans", "Arial", "sans-serif",
			])
			if "allow_system_fallback" in f:
				f.allow_system_fallback = true
			_body_font = _hard_edges(f)
	return _body_font

## ---------- CAJAS ----------

static func box(bg: Color, border: Color, border_w: int = 2) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.border_width_top = border_w
	sb.border_width_bottom = border_w
	sb.border_width_left = border_w
	sb.border_width_right = border_w
	sb.corner_radius_top_left = 0
	sb.corner_radius_top_right = 0
	sb.corner_radius_bottom_left = 0
	sb.corner_radius_bottom_right = 0
	sb.anti_aliasing = false
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	return sb

static func shadowed(sb: StyleBoxFlat, size: int = 2, alpha: float = 0.5, offset := Vector2(3, 3)) -> StyleBoxFlat:
	sb.shadow_size = size
	sb.shadow_color = Color(0, 0, 0, alpha)
	sb.shadow_offset = offset
	return sb

static func panel(highlight: bool = false) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := box(PANEL, GOLD if highlight else PANEL_BORDER, 2)
	shadowed(sb, 2, 0.45, Vector2(3, 3))
	p.add_theme_stylebox_override("panel", sb)
	return p

## ---------- TEXTO ----------
##
## Sin autoajuste por defecto: un Label con AUTOWRAP dentro de una caja
## estrecha parte el texto letra a letra y los nombres salen escritos en
## vertical. Para párrafos largos está paragraph().

static func title(text: String, size: int = 28, color: Color = GOLD) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", display())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	# La sombra se elige según el propio texto: negra debajo de una letra clara
	# la despega del fondo, pero debajo de una letra OSCURA (el banner dorado
	# de "es tu turno") la emborrona y deja de leerse. Ahí se usa un realce
	# claro, que funciona como un relieve grabado.
	var dark_text: bool = color.get_luminance() < 0.45
	l.add_theme_color_override("font_shadow_color",
		Color(1, 1, 1, 0.35) if dark_text else Color(0, 0, 0, 0.75))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1 if dark_text else 2)
	l.add_theme_constant_override("shadow_outline_size", 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	return l

static func label(text: String, size: int = 14, color: Color = TEXT, center: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	# SIN recorte por defecto: con OVERRUN_TRIM_ELLIPSIS un Label declara un
	# ancho mínimo casi nulo, y metido en una caja apretada el contenedor lo
	# encoge hasta hacerlo desaparecer. Así se esfumaban los nombres de los
	# rivales en sus asientos.
	l.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	if center:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l

static func paragraph(text: String, size: int = 14, color: Color = TEXT_MUTED, center: bool = true) -> Label:
	var l := label(text, size, color, center)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	l.custom_minimum_size = Vector2(200, 0)
	return l

## ---------- BOTONES ----------

static func _btn_box(bg: Color, border: Color, pad_top: int) -> StyleBoxFlat:
	var sb := box(bg, border, 2)
	sb.content_margin_top = pad_top
	sb.content_margin_bottom = 12 - (pad_top - 8)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	return sb

static func button(text: String, cb: Callable, kind: String = "ghost") -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	b.add_theme_font_override("font", display())
	b.add_theme_font_size_override("font_size", 14)
	b.clip_text = true

	var bg := PANEL_HI
	var border := PANEL_BORDER
	var fg := TEXT
	match kind:
		"primary":
			bg = GOLD
			border = GOLD_DARK
			fg = TEXT_DARK
		"danger":
			bg = Color("#6d2626")
			border = EMBER
			fg = Color("#ffd9c2")

	var normal := _btn_box(bg, border, 8)
	shadowed(normal, 2, 0.5, Vector2(3, 3))
	var hover := _btn_box(bg.lightened(0.12), GOLD, 8)
	shadowed(hover, 2, 0.5, Vector2(3, 3))
	# Al pulsar, el botón pierde la sombra y baja: se hunde de verdad.
	var pressed := _btn_box(bg.darkened(0.15), border, 10)
	var disabled := _btn_box(Color(bg, 0.25), Color(border, 0.3), 8)

	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", normal)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg)
	b.add_theme_color_override("font_pressed_color", fg)
	b.add_theme_color_override("font_disabled_color", Color(fg, 0.35))
	# El chasquido se engancha aquí y no en cada sitio: así TODO botón del
	# juego suena, sin que haya que acordarse de ponerlo uno por uno.
	b.pressed.connect(func(): Sfx.play("click"))
	if cb.is_valid():
		b.pressed.connect(cb)
	return b

## ---------- TEMA GLOBAL ----------

static func build_theme() -> Theme:
	var t := Theme.new()
	t.default_font = body()
	t.default_font_size = 14

	var le := box(PANEL_DEEP, PANEL_BORDER, 2)
	le.content_margin_left = 10
	le.content_margin_right = 10
	t.set_stylebox("normal", "LineEdit", le)
	var le_focus := box(PANEL_DEEP, GOLD, 2)
	le_focus.content_margin_left = 10
	le_focus.content_margin_right = 10
	t.set_stylebox("focus", "LineEdit", le_focus)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", Color(TEXT_MUTED, 0.7))
	t.set_color("caret_color", "LineEdit", GOLD)
	t.set_font_size("font_size", "LineEdit", 15)

	t.set_color("font_color", "Label", TEXT)
	return t
