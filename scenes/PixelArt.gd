class_name PixelArt
extends RefCounted
## PixelArt.gd
## Genera TODO el arte del juego como imágenes de baja resolución que luego se
## escalan con filtro NEAREST por múltiplos exactos (x1, x2, x3...). Ese es el
## truco para que se vea pixel art de verdad: se dibuja pequeño y se agranda
## a cascoporro, en vez de dibujar suave y fingirlo.
##
## Nada de esto son assets: se pinta píxel a píxel al arrancar y se cachea, así
## que el juego sigue sin depender de ninguna imagen externa.

## Tamaño base de una carta. Todo lo que se enseñe en pantalla debe ser un
## múltiplo entero de esto (40x56, 80x112, 120x168...) o los píxeles saldrán
## de distinto tamaño y se notará.
const W := 40
const H := 56

## ---------- PALETA DE TABERNA ----------

const INK := Color("#241610")
const PARCH := Color("#efe0bd")
const PARCH_HI := Color("#f8eed7")
const PARCH_LO := Color("#dbc59a")

const BACK := Color("#7d2f2f")
const BACK_DARK := Color("#4a1a1a")
const BACK_GOLD := Color("#d9a441")

const WOOD := Color("#5b3b24")
const WOOD_DARK := Color("#3a2416")
const WOOD_SEAM := Color("#2a1810")
const WOOD_LIGHT := Color("#6f4a2d")
const CANDLE := Color("#e8b061")

const SUIT_MAIN := {
	"oros": Color("#d9a441"),
	"copas": Color("#c2494b"),
	"espadas": Color("#4d80b8"),
	"bastos": Color("#5a9c4a"),
}
const SUIT_DARK := {
	"oros": Color("#9a6b1e"),
	"copas": Color("#8a2a2e"),
	"espadas": Color("#2b5382"),
	"bastos": Color("#356a2c"),
}

static func suit_main(suit: String) -> Color:
	return SUIT_MAIN.get(suit, Color("#888888"))

static func suit_dark(suit: String) -> Color:
	return SUIT_DARK.get(suit, Color("#444444"))

## ---------- CACHÉ ----------

static var _cards: Dictionary = {}
static var _back_tex: ImageTexture = null
static var _empty_tex: ImageTexture = null
static var _bg_tex: ImageTexture = null

## ---------- PRIMITIVAS DE PÍXEL ----------

static func _img(w: int, h: int) -> Image:
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	# Se limpia explícitamente: las llamas y las esquinas de las cartas
	# dependen de que lo que no se pinta quede transparente de verdad.
	img.fill(Color(0, 0, 0, 0))
	return img

static func _px(img: Image, x: int, y: int, c: Color) -> void:
	if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
		img.set_pixel(x, y, c)

static func _rect(img: Image, x: int, y: int, w: int, h: int, c: Color) -> void:
	for j in range(y, y + h):
		for i in range(x, x + w):
			_px(img, i, j, c)

static func _frame(img: Image, x: int, y: int, w: int, h: int, c: Color) -> void:
	for i in range(x, x + w):
		_px(img, i, y, c)
		_px(img, i, y + h - 1, c)
	for j in range(y, y + h):
		_px(img, x, j, c)
		_px(img, x + w - 1, j, c)

## Mezcla sobre lo que ya hay en vez de tapar. Es lo que permite grabar
## motivos "a fuego" en la madera: el dibujo oscurece la veta sin borrarla.
static func _shade(img: Image, x: int, y: int, c: Color, a: float) -> void:
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return
	img.set_pixel(x, y, img.get_pixel(x, y).lerp(c, a))

static func _shade_rect(img: Image, x: int, y: int, w: int, h: int, c: Color, a: float) -> void:
	for j in range(y, y + h):
		for i in range(x, x + w):
			_shade(img, i, j, c, a)

static func _disc(img: Image, cx: int, cy: int, r: int, c: Color) -> void:
	for j in range(cy - r, cy + r + 1):
		for i in range(cx - r, cx + r + 1):
			var dx := i - cx
			var dy := j - cy
			if dx * dx + dy * dy <= r * r:
				_px(img, i, j, c)

static func _ring(img: Image, cx: int, cy: int, r: int, c: Color) -> void:
	var inner := (r - 1) * (r - 1)
	for j in range(cy - r, cy + r + 1):
		for i in range(cx - r, cx + r + 1):
			var dx := i - cx
			var dy := j - cy
			var d := dx * dx + dy * dy
			if d <= r * r and d > inner:
				_px(img, i, j, c)

static func _line(img: Image, x0: int, y0: int, x1: int, y1: int, c: Color) -> void:
	# Bresenham: líneas de píxeles enteros, sin suavizado.
	var dx: int = abs(x1 - x0)
	var dy: int = -abs(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1
	var sy: int = 1 if y0 < y1 else -1
	var err := dx + dy
	var x := x0
	var y := y0
	while true:
		_px(img, x, y, c)
		if x == x1 and y == y1:
			break
		var e2 := err * 2
		if e2 >= dy:
			err += dy
			x += sx
		if e2 <= dx:
			err += dx
			y += sy

## Línea gruesa a base de líneas paralelas desplazadas.
static func _thick_line(img: Image, x0: int, y0: int, x1: int, y1: int, t: int, c: Color) -> void:
	var half: int = int(t / 2.0)
	for k in range(-half, t - half):
		_line(img, x0 + k, y0, x1 + k, y1, c)
		_line(img, x0, y0 + k, x1, y1 + k, c)

## ---------- TIPOGRAFÍA 3x5 ----------

const DIGITS := {
	"0": ["###", "# #", "# #", "# #", "###"],
	"1": [" # ", "## ", " # ", " # ", "###"],
	"2": ["###", "  #", "###", "#  ", "###"],
	"3": ["###", "  #", "###", "  #", "###"],
	"4": ["# #", "# #", "###", "  #", "  #"],
	"5": ["###", "#  ", "###", "  #", "###"],
	"6": ["###", "#  ", "###", "# #", "###"],
	"7": ["###", "  #", "  #", "  #", "  #"],
	"8": ["###", "# #", "###", "# #", "###"],
	"9": ["###", "# #", "###", "  #", "###"],
}

## Fuente grande para el índice de las esquinas. El juego entero consiste en
## emparejar números, así que el número tiene que leerse de un vistazo desde
## el otro lado de la mesa; con 3x5 se quedaba corto.
const DIGITS_BIG := {
	"0": ["#####", "#   #", "#   #", "#   #", "#   #", "#   #", "#####"],
	"1": ["  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "],
	"2": ["#####", "    #", "    #", "#####", "#    ", "#    ", "#####"],
	"3": ["#####", "    #", "    #", "#####", "    #", "    #", "#####"],
	"4": ["#   #", "#   #", "#   #", "#####", "    #", "    #", "    #"],
	"5": ["#####", "#    ", "#    ", "#####", "    #", "    #", "#####"],
	"6": ["#####", "#    ", "#    ", "#####", "#   #", "#   #", "#####"],
	"7": ["#####", "    #", "    #", "   # ", "  #  ", "  #  ", "  #  "],
	"8": ["#####", "#   #", "#   #", "#####", "#   #", "#   #", "#####"],
	"9": ["#####", "#   #", "#   #", "#####", "    #", "    #", "#####"],
}

static func digits_width(text: String) -> int:
	return max(0, text.length() * 4 - 1)

static func big_width(text: String) -> int:
	return max(0, text.length() * 6 - 1)

## El índice NO se dibuja girado en la esquina opuesta. En un naipe de verdad
## sí va invertido, pero a esta resolución un número girado deja de parecer un
## número y se lee como una letra suelta.
static func _digits_big(img: Image, x: int, y: int, text: String, c: Color, shadow: Color) -> void:
	for n in range(text.length()):
		var glyph: Array = DIGITS_BIG.get(text[n], ["     ", "     ", "     ", "     ", "     ", "     ", "     "])
		for row in range(7):
			var line: String = glyph[row]
			for col in range(5):
				if line[col] != "#":
					continue
				# Sombra de un píxel abajo-derecha: despega el número del
				# pergamino sin recurrir a suavizados.
				_px(img, x + n * 6 + col + 1, y + row + 1, shadow)
	for n in range(text.length()):
		var glyph2: Array = DIGITS_BIG.get(text[n], ["     ", "     ", "     ", "     ", "     ", "     ", "     "])
		for row in range(7):
			var line2: String = glyph2[row]
			for col in range(5):
				if line2[col] == "#":
					_px(img, x + n * 6 + col, y + row, c)

## flip=true dibuja el número girado 180°, para el índice de la esquina opuesta.
static func _digits(img: Image, x: int, y: int, text: String, c: Color, flip: bool = false) -> void:
	var total := digits_width(text)
	for n in range(text.length()):
		var glyph: Array = DIGITS.get(text[n], ["   ", "   ", "   ", "   ", "   "])
		for row in range(5):
			var line: String = glyph[row]
			for col in range(3):
				if line[col] != "#":
					continue
				if flip:
					_px(img, x + total - 1 - (n * 4 + col), y + 4 - row, c)
				else:
					_px(img, x + n * 4 + col, y + row, c)

## ---------- PALOS ----------
##
## Cada palo se dibuja centrado en (20, 25) dentro de la carta de 40x56, con
## un tono principal y otro más oscuro para dar volumen.

static func _suit(img: Image, suit: String, cx: int, cy: int) -> void:
	var m := suit_main(suit)
	var d := suit_dark(suit)
	match suit:
		"oros": _oros(img, cx, cy, m, d)
		"copas": _copas(img, cx, cy, m, d)
		"espadas": _espadas(img, cx, cy, m, d)
		"bastos": _bastos(img, cx, cy, m, d)

static func _oros(img: Image, cx: int, cy: int, m: Color, d: Color) -> void:
	_disc(img, cx, cy, 9, m)
	_ring(img, cx, cy, 9, d)
	_ring(img, cx, cy, 6, d)
	# Sol interior de cuatro puntas.
	for i in range(-3, 4):
		_px(img, cx + i, cy, d)
		_px(img, cx, cy + i, d)
	_px(img, cx - 2, cy - 2, d)
	_px(img, cx + 2, cy - 2, d)
	_px(img, cx - 2, cy + 2, d)
	_px(img, cx + 2, cy + 2, d)
	# Brillo arriba a la izquierda: la moneda deja de ser un círculo plano.
	_px(img, cx - 5, cy - 6, PARCH_HI)
	_px(img, cx - 4, cy - 6, PARCH_HI)
	_px(img, cx - 6, cy - 5, PARCH_HI)

static func _copas(img: Image, cx: int, cy: int, m: Color, d: Color) -> void:
	var top := cy - 10
	_rect(img, cx - 7, top, 15, 2, m)          # labio
	var widths := [6, 6, 5, 5, 4, 3, 2]
	for i in range(widths.size()):
		var hw: int = widths[i]
		_rect(img, cx - hw, top + 2 + i, hw * 2 + 1, 1, m)
	_rect(img, cx - 1, top + 9, 3, 6, m)       # pie
	_rect(img, cx - 5, top + 15, 11, 2, m)     # base
	_rect(img, cx - 6, top + 17, 13, 1, d)
	# Sombra del lado derecho.
	for i in range(widths.size()):
		_px(img, cx + widths[i], top + 2 + i, d)
	_px(img, cx + 7, top, d)
	_px(img, cx + 7, top + 1, d)
	_px(img, cx + 1, top + 9 + 3, d)

static func _espadas(img: Image, cx: int, cy: int, m: Color, d: Color) -> void:
	var top := cy - 12
	_px(img, cx, top, m)                        # punta
	_rect(img, cx - 1, top + 1, 3, 2, m)
	_rect(img, cx - 2, top + 3, 5, 10, m)       # hoja
	_rect(img, cx - 7, top + 13, 15, 2, m)      # gavilanes
	_rect(img, cx - 1, top + 15, 3, 5, m)       # empuñadura
	_rect(img, cx - 2, top + 20, 5, 2, m)       # pomo
	# Filo oscuro a la derecha y canal central claro.
	for j in range(top + 3, top + 13):
		_px(img, cx + 2, j, d)
		_px(img, cx, j, PARCH_HI)
	_px(img, cx + 7, top + 14, d)
	_px(img, cx - 7, top + 14, d)

static func _bastos(img: Image, cx: int, cy: int, m: Color, d: Color) -> void:
	var x0 := cx - 7
	var y0 := cy + 11
	var x1 := cx + 7
	var y1 := cy - 11
	_thick_line(img, x0, y0, x1, y1, 5, m)
	_disc(img, x0, y0, 3, m)
	_disc(img, x1, y1, 2, m)
	# Muñones: las dos ramas cortadas que distinguen un basto de un palo.
	_thick_line(img, cx - 3, cy + 4, cx - 8, cy + 1, 3, m)
	_thick_line(img, cx + 3, cy - 3, cx + 8, cy - 6, 3, m)
	# Nudos y sombra inferior.
	_px(img, cx - 3, cy + 3, d)
	_px(img, cx + 1, cy - 1, d)
	_px(img, cx + 4, cy - 5, d)
	_line(img, x0 - 1, y0 + 1, x1 - 1, y1 + 1, d)

## ---------- ICONOS DE EFECTO ----------

## Ojo: lente en forma de rombo con la pupila del color de la franja.
static func _eye(img: Image, cx: int, cy: int, c: Color, pupil: Color) -> void:
	_rect(img, cx - 1, cy - 2, 3, 1, c)
	_rect(img, cx - 2, cy - 1, 5, 1, c)
	_rect(img, cx - 4, cy, 9, 1, c)
	_rect(img, cx - 2, cy + 1, 5, 1, c)
	_rect(img, cx - 1, cy + 2, 3, 1, c)
	_px(img, cx, cy, pupil)
	_px(img, cx, cy - 1, pupil)

## Dos flechas cruzadas: una va y otra viene, que es exactamente lo que hace
## el 11.
static func _swap(img: Image, cx: int, cy: int, c: Color) -> void:
	_rect(img, cx - 4, cy - 2, 7, 1, c)
	_px(img, cx + 2, cy - 3, c)
	_px(img, cx + 3, cy - 2, c)
	_px(img, cx + 2, cy - 1, c)
	_rect(img, cx - 2, cy + 1, 7, 1, c)
	_px(img, cx - 2, cy, c)
	_px(img, cx - 3, cy + 1, c)
	_px(img, cx - 2, cy + 2, c)

## ---------- CARTAS ----------

static func card_texture(card_id: String) -> ImageTexture:
	if _cards.has(card_id):
		return _cards[card_id]
	var suit := CardData.parse_suit(card_id)
	var number := CardData.parse_number(card_id)
	var m := suit_main(suit)
	var d := suit_dark(suit)

	var img := _img(W, H)
	# Cuerpo de pergamino con banda clara arriba y oscura abajo.
	_rect(img, 1, 1, W - 2, H - 2, PARCH)
	_rect(img, 2, 2, W - 4, 6, PARCH_HI)
	_rect(img, 2, H - 8, W - 4, 6, PARCH_LO)
	# Contorno con las esquinas recortadas (así se redondea en pixel art).
	_frame(img, 0, 0, W, H, INK)
	for corner in [[0, 0], [W - 1, 0], [0, H - 1], [W - 1, H - 1]]:
		_px(img, corner[0], corner[1], Color(0, 0, 0, 0))
	# Filete interior del color del palo.
	_frame(img, 2, 2, W - 4, H - 4, m)

	var label := str(number)
	var special: bool = number == 10 or number == 11 or number == 12

	_digits_big(img, 4, 5, label, d, PARCH_LO)
	_suit(img, suit, 20, 26)

	if special:
		# Franja inferior con el efecto de la carta. Es lo que hace que nadie
		# tenga que acordarse de qué hacía cada figura.
		_rect(img, 3, H - 12, W - 6, 9, m)
		if number == 10:
			_eye(img, 20, H - 8, PARCH, m)
		elif number == 11:
			_swap(img, 20, H - 8, PARCH)
		else:
			var pts := "0" if (suit == "espadas" or suit == "oros") else "30"
			_digits(img, 20 - int(digits_width(pts) / 2.0), H - 10, pts, PARCH)
	else:
		_digits_big(img, W - 5 - big_width(label), H - 13, label, d, PARCH_LO)

	var tex := ImageTexture.create_from_image(img)
	_cards[card_id] = tex
	return tex

static func back_texture() -> ImageTexture:
	if _back_tex != null:
		return _back_tex
	var img := _img(W, H)
	_rect(img, 1, 1, W - 2, H - 2, BACK)
	_frame(img, 0, 0, W, H, INK)
	for corner in [[0, 0], [W - 1, 0], [0, H - 1], [W - 1, H - 1]]:
		_px(img, corner[0], corner[1], Color(0, 0, 0, 0))
	_frame(img, 2, 2, W - 4, H - 4, BACK_GOLD)
	_frame(img, 3, 3, W - 6, H - 6, BACK_DARK)
	# Celosía de rombos.
	for y in range(6, H - 6, 6):
		for x in range(6, W - 6, 6):
			var ox: int = x + (3 if (y / 6) % 2 == 0 else 0)
			if ox >= W - 6:
				continue
			_px(img, ox, y - 1, BACK_GOLD)
			_px(img, ox - 1, y, BACK_GOLD)
			_px(img, ox + 1, y, BACK_GOLD)
			_px(img, ox, y + 1, BACK_GOLD)
	# Medallón central.
	_disc(img, 20, 28, 7, BACK_DARK)
	_ring(img, 20, 28, 7, BACK_GOLD)
	for i in range(-4, 5):
		_px(img, 20 + i, 28, BACK_GOLD)
		_px(img, 20, 28 + i, BACK_GOLD)
	_back_tex = ImageTexture.create_from_image(img)
	return _back_tex

static func empty_texture() -> ImageTexture:
	if _empty_tex != null:
		return _empty_tex
	var img := _img(W, H)
	var c := Color(1, 1, 1, 0.20)
	for i in range(1, W - 1):
		if i % 4 < 2:
			_px(img, i, 0, c)
			_px(img, i, H - 1, c)
	for j in range(1, H - 1):
		if j % 4 < 2:
			_px(img, 0, j, c)
			_px(img, W - 1, j, c)
	_empty_tex = ImageTexture.create_from_image(img)
	return _empty_tex

## ---------- HERÁLDICA ----------
##
## Motivos de la época que se usan tanto grabados a fuego en la mesa como
## bordados en los estandartes de la taberna.

static func _tower(img: Image, x: int, w: int, top: int, bottom: int, c: Color, a: float) -> void:
	# Almenas: dos píxeles de merlón y dos de hueco.
	for i in range(0, w, 4):
		_shade_rect(img, x + i, top, 2, 3, c, a)
	_shade_rect(img, x, top + 3, w, bottom - top - 3, c, a)

## Castillo de tres torres, el del escudo de Castilla. El hueco de la puerta se
## deja sin pintar en vez de dibujarlo: así conserva la veta de la madera.
static func _castle(img: Image, cx: int, cy: int, c: Color, a: float) -> void:
	var bottom := cy + 11
	_tower(img, cx - 15, 10, cy - 7, bottom, c, a)
	_tower(img, cx - 5, 10, cy - 13, bottom, c, a)
	_tower(img, cx + 5, 10, cy - 7, bottom, c, a)
	_shade_rect(img, cx - 17, cy - 2, 14, 13, c, a)
	_shade_rect(img, cx + 3, cy - 2, 14, 13, c, a)
	_shade_rect(img, cx - 3, cy - 2, 6, 4, c, a)
	_shade_rect(img, cx - 18, bottom, 36, 3, c, a)

## Cruz patada: los brazos se ensanchan en las puntas.
static func _cross(img: Image, cx: int, cy: int, c: Color, a: float) -> void:
	_shade_rect(img, cx - 1, cy - 6, 3, 13, c, a)
	_shade_rect(img, cx - 6, cy - 1, 13, 3, c, a)
	_shade_rect(img, cx - 2, cy - 8, 5, 2, c, a)
	_shade_rect(img, cx - 2, cy + 7, 5, 2, c, a)
	_shade_rect(img, cx - 8, cy - 2, 2, 5, c, a)
	_shade_rect(img, cx + 7, cy - 2, 2, 5, c, a)

## Filigrana de esquina: una espiral escalonada, como las de los cueros
## repujados.
static func _corner_flourish(img: Image, x: int, y: int, sx: int, sy: int, c: Color, a: float) -> void:
	for i in range(9):
		_shade(img, x + sx * i, y, c, a)
		_shade(img, x, y + sy * i, c, a)
	for i in range(5):
		_shade(img, x + sx * (4 + i), y + sy * 4, c, a)
		_shade(img, x + sx * 4, y + sy * (4 + i), c, a)
	_shade(img, x + sx * 7, y + sy * 7, c, a)
	_shade(img, x + sx * 8, y + sy * 7, c, a)
	_shade(img, x + sx * 7, y + sy * 8, c, a)

## ---------- FONDO DE TABERNA ----------
##
## Mesa de madera vista desde arriba, con la luz de una vela cayendo desde el
## fondo, vetas, nudos y un par de cercos de jarra. 240x135 escalado x4 da
## exactamente 960x540.

const BG_W := 240
const BG_H := 135

static func _hash(x: int, y: int) -> float:
	var n: int = x * 374761393 + y * 668265263
	n = (n ^ (n >> 13)) * 1274126177
	return float((n ^ (n >> 16)) & 0xFFFF) / 65535.0

static func tavern_background() -> ImageTexture:
	if _bg_tex != null:
		return _bg_tex
	var img := _img(BG_W, BG_H)
	var plank_h := 17
	var light_x := BG_W * 0.5
	var light_y := BG_H * 0.30
	var max_d := sqrt(BG_W * BG_W + BG_H * BG_H) * 0.62

	for y in range(BG_H):
		var plank: int = int(y / plank_h)
		var in_seam: bool = (y % plank_h) == 0 or (y % plank_h) == plank_h - 1
		for x in range(BG_W):
			var c := WOOD
			# Cada tabla tiene su propio tono: la madera nunca es uniforme.
			var tone := _hash(plank, 7) * 0.5
			c = WOOD.lerp(WOOD_LIGHT if tone > 0.25 else WOOD_DARK, abs(tone - 0.25))
			# Veta: rayas horizontales largas y finas.
			var grain := _hash(int(x / 3.0), y * 3 + plank)
			if grain > 0.86:
				c = c.lerp(WOOD_DARK, 0.45)
			elif grain < 0.06:
				c = c.lerp(WOOD_LIGHT, 0.35)
			if in_seam:
				c = WOOD_SEAM
			# Luz cálida de vela.
			var dx := x - light_x
			var dy := (y - light_y) * 1.4
			var d: float = sqrt(dx * dx + dy * dy)
			var lit: float = clamp(1.0 - d / max_d, 0.0, 1.0)
			c = c.lerp(CANDLE, lit * lit * 0.42)
			# Viñeteado: los bordes se van a oscuras.
			c = c.lerp(Color.BLACK, clamp((d / max_d - 0.55) * 0.75, 0.0, 0.5))
			img.set_pixel(x, y, c)

	# Nudos de la madera.
	for k in range(6):
		var kx: int = int(_hash(k, 91) * BG_W)
		var ky: int = int(_hash(k, 57) * BG_H)
		_ring(img, kx, ky, 4, WOOD_DARK.lerp(Color.BLACK, 0.3))
		_ring(img, kx, ky, 2, WOOD_DARK)

	# Cercos de jarra: la mesa de una taberna tiene marcas de uso.
	_stain(img, 46, 104, 15)
	_stain(img, 202, 34, 12)
	_stain(img, 190, 112, 10)

	# Grabado a fuego: doble filete perimetral, filigranas en las esquinas,
	# cruces en los laterales y el castillo en el centro. Todo a poca mezcla,
	# porque esto tiene que quedar POR DEBAJO de las cartas y no competir con
	# ellas: se lee cuando miras la mesa, no cuando miras tu mano.
	var burn := WOOD_SEAM
	for x in range(9, BG_W - 9):
		_shade(img, x, 9, burn, 0.30)
		_shade(img, x, 12, burn, 0.18)
		_shade(img, x, BG_H - 10, burn, 0.30)
		_shade(img, x, BG_H - 13, burn, 0.18)
	for y in range(9, BG_H - 9):
		_shade(img, 9, y, burn, 0.30)
		_shade(img, 12, y, burn, 0.18)
		_shade(img, BG_W - 10, y, burn, 0.30)
		_shade(img, BG_W - 13, y, burn, 0.18)
	_corner_flourish(img, 15, 15, 1, 1, burn, 0.28)
	_corner_flourish(img, BG_W - 16, 15, -1, 1, burn, 0.28)
	_corner_flourish(img, 15, BG_H - 16, 1, -1, burn, 0.28)
	_corner_flourish(img, BG_W - 16, BG_H - 16, -1, -1, burn, 0.28)
	_castle(img, 120, 74, burn, 0.22)
	_cross(img, 34, 67, burn, 0.20)
	_cross(img, 206, 67, burn, 0.20)

	_bg_tex = ImageTexture.create_from_image(img)
	return _bg_tex

## ---------- INTERIOR DE LA TABERNA ----------
##
## El fondo de los menús: pared de sillería, vigas, dos antorchas encendidas y
## un estandarte con el castillo. Aquí no hay cartas encima, así que se puede
## cargar mucho más la escena.

static var _scene_tex: ImageTexture = null

## Dónde están las antorchas dentro de la imagen de 240x135. MenuFx lo usa
## para colocar las llamas animadas justo encima de cada tea.
const TORCH_POS := [Vector2(40, 44), Vector2(200, 44)]

const STONE := Color("#4a4038")
const STONE_HI := Color("#5c5148")
const STONE_LO := Color("#39312a")
const MORTAR := Color("#2a2420")
const FLAME_OUT := Color("#ff8c3a")
const FLAME_MID := Color("#ffd36a")
const FLAME_CORE := Color("#fff3cc")

static func tavern_scene() -> ImageTexture:
	if _scene_tex != null:
		return _scene_tex
	var img := _img(BG_W, BG_H)
	var floor_y := 104

	# --- sillería ---
	var block_w := 22
	var block_h := 11
	for y in range(0, floor_y):
		for x in range(BG_W):
			var row: int = int(y / block_h)
			var offset: int = (row % 2) * int(block_w / 2.0)
			var bx: int = int((x + offset) / block_w)
			var c := STONE
			var v := _hash(bx, row)
			c = STONE.lerp(STONE_HI if v > 0.5 else STONE_LO, abs(v - 0.5) * 0.9)
			# Junta de mortero entre sillares.
			if (y % block_h) == 0 or ((x + offset) % block_w) == 0:
				c = MORTAR
			# Grano de la piedra.
			if _hash(x * 2, y * 5) > 0.90:
				c = c.lerp(STONE_LO, 0.5)
			img.set_pixel(x, y, c)

	# --- viga superior y postes ---
	_rect(img, 0, 0, BG_W, 11, WOOD_DARK)
	for x in range(BG_W):
		if _hash(x, 3) > 0.7:
			_rect(img, x, 2, 1, 7, WOOD_SEAM)
	_rect(img, 0, 10, BG_W, 1, WOOD_SEAM)
	for post_x in [0, BG_W - 9]:
		_rect(img, post_x, 0, 9, floor_y, WOOD)
		_rect(img, post_x, 0, 1, floor_y, WOOD_SEAM)
		_rect(img, post_x + 8, 0, 1, floor_y, WOOD_SEAM)
		for y in range(0, floor_y, 3):
			if _hash(post_x + y, 11) > 0.6:
				_rect(img, post_x + 2, y, 5, 1, WOOD_DARK)

	# --- suelo de tablas ---
	for y in range(floor_y, BG_H):
		for x in range(BG_W):
			var plank: int = int((y - floor_y) / 9.0)
			var c2 := WOOD.lerp(WOOD_DARK if _hash(plank, 3) > 0.5 else WOOD_LIGHT, 0.25)
			if (y - floor_y) % 9 == 0:
				c2 = WOOD_SEAM
			if _hash(int(x / 4.0), y * 3) > 0.88:
				c2 = c2.lerp(WOOD_DARK, 0.4)
			img.set_pixel(x, y, c2)
	_rect(img, 0, floor_y - 2, BG_W, 2, WOOD_SEAM)

	# --- estandarte con el castillo ---
	_banner(img, 120, 14, 46, 72)

	# --- antorchas ---
	_torch(img, 40, 44)
	_torch(img, 200, 44)

	# --- attrezzo: barricas y una repisa con jarras ---
	_barrel(img, 26, floor_y + 26)
	_barrel(img, 214, floor_y + 26)
	_shelf(img, 143, 74, 34)

	# --- luz: cálida desde las antorchas, oscura en las esquinas ---
	for y in range(BG_H):
		for x in range(BG_W):
			var c3 := img.get_pixel(x, y)
			var lit := 0.0
			for t in [Vector2(40, 38), Vector2(200, 38)]:
				var d: float = sqrt(pow(x - t.x, 2.0) + pow((y - t.y) * 1.15, 2.0))
				lit = max(lit, clamp(1.0 - d / 92.0, 0.0, 1.0))
			c3 = c3.lerp(CANDLE, lit * lit * 0.5)
			var edge: float = max(
				max(0.0, 1.0 - x / 46.0),
				max(0.0, 1.0 - (BG_W - x) / 46.0))
			edge = max(edge, max(0.0, 1.0 - (BG_H - y) / 30.0))
			c3 = c3.lerp(Color.BLACK, edge * 0.35)
			img.set_pixel(x, y, c3)

	_scene_tex = ImageTexture.create_from_image(img)
	return _scene_tex

static func _banner(img: Image, cx: int, top: int, w: int, h: int) -> void:
	var x0: int = cx - int(w / 2.0)
	# Barra de la que cuelga.
	_rect(img, x0 - 6, top - 3, w + 12, 3, WOOD_DARK)
	_rect(img, x0 - 6, top - 3, w + 12, 1, WOOD_LIGHT)
	# Paño.
	_rect(img, x0, top, w, h, BACK)
	_rect(img, x0, top, w, 2, BACK_DARK)
	_rect(img, x0, top, 2, h, BACK_DARK)
	_rect(img, x0 + w - 2, top, 2, h, BACK_DARK)
	# Ribete dorado.
	_rect(img, x0 + 3, top + 3, w - 6, 1, BACK_GOLD)
	_rect(img, x0 + 3, top + h - 4, w - 6, 1, BACK_GOLD)
	# Picos inferiores.
	for i in range(10):
		_rect(img, x0, top + h + i, int(w / 2.0) - i * 2, 1, BACK)
		_rect(img, cx + i * 2, top + h + i, int(w / 2.0) - i * 2, 1, BACK)
	_castle(img, cx, top + int(h / 2.0), BACK_GOLD, 1.0)

## Barrica: duelas verticales, más ancha por el centro que por los extremos, y
## dos aros de hierro. Se dibuja de abajo hacia arriba desde base_y.
static func _barrel(img: Image, cx: int, base_y: int) -> void:
	var h := 30
	var top := base_y - h
	# Sombra en el suelo.
	_shade_rect(img, cx - 12, base_y, 24, 2, Color.BLACK, 0.35)
	for j in range(h):
		# El perfil se abomba: estrecho arriba y abajo, ancho en el medio.
		var t: float = float(j) / float(h - 1)
		var hw: int = 8 + int(round(sin(t * PI) * 3.0))
		for i in range(-hw, hw + 1):
			var c := WOOD
			# Duelas: una junta oscura cada tres píxeles.
			if (i + hw) % 4 == 0:
				c = WOOD_DARK
			elif i < -hw + 3:
				c = WOOD_LIGHT
			_px(img, cx + i, top + j, c)
		_px(img, cx - hw, top + j, WOOD_SEAM)
		_px(img, cx + hw, top + j, WOOD_SEAM)
	# Aros.
	for band in [6, h - 8]:
		var t2: float = float(band) / float(h - 1)
		var hw2: int = 8 + int(round(sin(t2 * PI) * 3.0))
		_rect(img, cx - hw2, top + band, hw2 * 2 + 1, 2, Color("#3a3a40"))
	# Tapa superior.
	_rect(img, cx - 8, top, 17, 2, WOOD_LIGHT)
	_rect(img, cx - 8, top, 17, 1, WOOD_DARK)

## Repisa con tres jarras: el detalle que convierte una pared en una taberna.
static func _shelf(img: Image, x: int, y: int, w: int) -> void:
	_rect(img, x, y, w, 3, WOOD)
	_rect(img, x, y + 2, w, 1, WOOD_SEAM)
	_rect(img, x + 2, y + 3, 2, 3, WOOD_DARK)
	_rect(img, x + w - 4, y + 3, 2, 3, WOOD_DARK)
	var pewter := Color("#6d6a63")
	var pewter_hi := Color("#8a877e")
	for k in range(3):
		var mx: int = x + 4 + k * 11
		var my: int = y - 8
		_rect(img, mx, my, 7, 8, pewter)
		_rect(img, mx, my, 7, 1, pewter_hi)
		_rect(img, mx + 1, my + 1, 2, 6, pewter_hi)
		# Asa.
		_px(img, mx + 7, my + 2, pewter)
		_px(img, mx + 8, my + 3, pewter)
		_px(img, mx + 8, my + 4, pewter)
		_px(img, mx + 7, my + 5, pewter)

## Sólo el soporte de hierro y la tea: la LLAMA no se hornea en el fondo,
## porque va animada encima (ver MenuFx). Si se dibujara aquí además, se vería
## la llama quieta asomando por detrás de la que se mueve.
static func _torch(img: Image, x: int, y: int) -> void:
	_rect(img, x - 1, y, 3, 16, Color("#2b2b2f"))
	_rect(img, x - 4, y + 14, 9, 3, Color("#2b2b2f"))
	_rect(img, x - 3, y - 2, 7, 4, Color("#3a3226"))
	# Punta de la tea, ya ennegrecida por el fuego.
	_rect(img, x - 2, y - 5, 5, 4, Color("#241b14"))

## ---------- LLAMA ANIMADA ----------
##
## Cuatro fotogramas de una llama en forma de lágrima. La punta ondea de un
## fotograma a otro; al pasarlos en bucle el fuego "respira".

const FLAME_W := 13
const FLAME_H := 22

static var _flame_frames: Array = []

static func flame_frames() -> Array:
	if not _flame_frames.is_empty():
		return _flame_frames
	for f in range(4):
		_flame_frames.append(_make_flame(f))
	return _flame_frames

static func _make_flame(f: int) -> ImageTexture:
	var img := _img(FLAME_W, FLAME_H)
	var cx := int(FLAME_W / 2.0)
	for j in range(FLAME_H):
		# t = 0 en la punta, 1 en la base.
		var t: float = float(j) / float(FLAME_H - 1)
		# Perfil de hoja: punta arriba, panza en el centro y vuelve a
		# estrecharse abajo, donde nace de la tea. El seno con el exponente es
		# lo que traslada la panza por encima de la mitad, como el fuego real.
		# El factor por fotograma hace que además de ondear, parpadee de ancho.
		var hw: int = int(round(5.2 * sin(pow(t, 0.75) * PI * 0.92) * (1.0 + 0.07 * sin(f * 2.1))))
		if hw <= 0:
			continue
		# El coleteo sólo afecta a la mitad superior: la base está sujeta a la
		# tea y no se mueve.
		var sway: int = int(round(sin((1.0 - t) * 3.4 + f * 1.55) * (1.0 - t) * 2.6))
		var mid: int = hw - 2
		var core: int = hw - 3
		for i in range(-hw, hw + 1):
			var c := FLAME_OUT
			if mid > 0 and abs(i) <= mid:
				c = FLAME_MID
			if core > 0 and abs(i) <= core and t > 0.3:
				c = FLAME_CORE
			_px(img, cx + i + sway, j, c)
	return ImageTexture.create_from_image(img)

static func _stain(img: Image, cx: int, cy: int, r: int) -> void:
	for j in range(cy - r, cy + r + 1):
		for i in range(cx - r, cx + r + 1):
			if i < 0 or j < 0 or i >= img.get_width() or j >= img.get_height():
				continue
			var dx := i - cx
			var dy := j - cy
			var d: float = sqrt(float(dx * dx + dy * dy))
			if d <= r and d > r - 1.6:
				img.set_pixel(i, j, img.get_pixel(i, j).lerp(WOOD_SEAM, 0.35))
