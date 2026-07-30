class_name MenuFx
extends Control
## MenuFx.gd
## Capa animada que se pinta ENTRE el fondo de la taberna y la interfaz, sólo
## en los menús. Da vida a la escena: las antorchas arden, sueltan brasas que
## suben y la luz de la sala late.
##
## Todo va sincronizado con la música de verdad, no con un temporizador: Music
## analiza el espectro y expone la energía de los graves, y de ahí salen tanto
## el tamaño de la llama como los golpes de luz y las tandas de brasas.
##
## Las coordenadas se dan en el espacio del fondo (240x135) y se convierten a
## pantalla al dibujar, así la escena encaja sea cual sea la resolución.

const EMBER_COLORS := [
	Color("#ffd36a"), Color("#ff8c3a"), Color("#e8b061"),
]

var _t: float = 0.0
var _spawn_acc: float = 0.0
var _embers: Array = []

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	set_process(true)

## Un píxel del fondo, en píxeles de pantalla. Se redondea a entero para que
## las brasas caigan en la misma rejilla que el resto del pixel art.
func _unit() -> float:
	return max(1.0, floor(size.y / float(PixelArt.BG_H)))

func _to_screen(p: Vector2) -> Vector2:
	return Vector2(
		p.x / float(PixelArt.BG_W) * size.x,
		p.y / float(PixelArt.BG_H) * size.y)

func _process(delta: float) -> void:
	_t += delta
	var beat: float = Music.beat()

	# Las brasas salen a un ritmo base y en tandas con cada golpe grave.
	_spawn_acc += delta * (7.0 + beat * 26.0)
	while _spawn_acc >= 1.0:
		_spawn_acc -= 1.0
		_spawn_ember()

	var alive: Array = []
	for e in _embers:
		e.life -= delta
		if e.life <= 0.0:
			continue
		# Suben, aceleran hacia arriba y culebrean: nunca en línea recta.
		# Los vectores se sacan y se vuelven a meter en vez de tocarlos en su
		# sitio: Vector2 es un valor, no una referencia.
		var v: Vector2 = e.vel
		v.y = max(v.y - delta * 4.0, -26.0)
		var p: Vector2 = e.pos
		p += v * delta
		p.x += sin(_t * 2.4 + e.seed) * delta * 5.0
		e.vel = v
		e.pos = p
		alive.append(e)
	_embers = alive

	queue_redraw()

func _spawn_ember() -> void:
	var torch: Vector2 = PixelArt.TORCH_POS[randi() % PixelArt.TORCH_POS.size()]
	_embers.append({
		"pos": torch + Vector2(randf_range(-2.5, 2.5), -10.0),
		"vel": Vector2(randf_range(-3.0, 3.0), randf_range(-14.0, -7.0)),
		"life": randf_range(1.1, 2.4),
		"max_life": 2.4,
		"seed": randf() * TAU,
		"color": EMBER_COLORS[randi() % EMBER_COLORS.size()],
	})

func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var unit := _unit()
	var beat: float = Music.beat()
	var level: float = Music.level()

	# Halo de cada antorcha: discos concéntricos de radio múltiplo del píxel,
	# así los escalones de luz caen en la rejilla y parecen intencionados.
	for i in range(PixelArt.TORCH_POS.size()):
		var torch: Vector2 = PixelArt.TORCH_POS[i]
		var center := _to_screen(torch + Vector2(0, -8))
		var glow: float = 0.55 + 0.45 * level
		for ring in range(5, 0, -1):
			var r: float = unit * ring * 7.0 * (0.9 + beat * 0.18)
			draw_circle(center, r, Color(PixelArt.CANDLE, 0.035 * glow))

	# Llamas: el fotograma avanza solo y el tamaño late con la música. Cada
	# antorcha va desfasada para que no ardan las dos a la vez, que canta.
	var frames: Array = PixelArt.flame_frames()
	for i in range(PixelArt.TORCH_POS.size()):
		var torch2: Vector2 = PixelArt.TORCH_POS[i]
		var frame: int = int(_t * 11.0 + i * 2.0) % frames.size()
		var tex: Texture2D = frames[frame]
		var scale_y: float = 1.0 + beat * 0.35 + sin(_t * 5.3 + i) * 0.06
		var w: float = PixelArt.FLAME_W * unit
		var h: float = PixelArt.FLAME_H * unit * scale_y
		# Anclada por la base, sobre la tea: al crecer tira hacia arriba.
		var base := _to_screen(torch2 + Vector2(0, -4))
		draw_texture_rect(tex, Rect2(base - Vector2(w * 0.5, h), Vector2(w, h)), false)

	# Brasas.
	for e in _embers:
		var a: float = clamp(e.life / e.max_life, 0.0, 1.0)
		var p := _to_screen(e.pos)
		draw_rect(Rect2(p.snapped(Vector2(unit, unit)), Vector2(unit, unit)),
			Color(e.color, a * 0.9), true)

	# La sala entera respira: un velo cálido que sube con los graves.
	draw_rect(Rect2(Vector2.ZERO, size), Color(PixelArt.CANDLE, 0.02 + beat * 0.05), true)
