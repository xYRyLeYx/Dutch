extends Node
## Autoload: Sfx
##
## Todos los efectos del juego, SINTETIZADOS por código. No hay ni un archivo
## de audio: se generan las muestras a mano, se meten en un AudioStreamWAV y se
## cachean.
##
## La síntesis imita INSTRUMENTOS REALES, no chips de consola: cuerda pulsada
## por Karplus-Strong para el laúd, parciales inarmónicos que caen rápido para
## los golpes de madera, ruido en paso alto para el roce del papel y soplos con
## envolvente de campana para el fuego. Nada de ondas cuadradas ni de arpegios
## de ocho bits, que es lo que hacía que un juego de taberna sonara a
## marcianitos.
##
## Generarlos cuesta unas décimas de segundo; a cambio, reproducir uno después
## no cuesta nada.

const RATE := 22050
const VOICES := 8

var _cache: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _next: int = 0
var _bus_idx: int = -1

const NAMES := [
	"click", "card", "draw", "place", "flip", "shuffle",
	"burn", "burn_fail", "dutch", "turn", "chime", "swap", "win", "lose",
]

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_bus()
	for i in range(VOICES):
		var p := AudioStreamPlayer.new()
		p.bus = "Sfx" if _bus_idx != -1 else "Master"
		add_child(p)
		_players.append(p)
	# Sintetizarlos todos lleva unas décimas de segundo. Se hace en diferido
	# para que la primera imagen del juego no se quede esperando: play() se
	# limita a no sonar si le piden un efecto que todavía no existe, y para
	# cuando alguien toca algo ya están listos.
	call_deferred("_build_all")

func _build_all() -> void:
	for n in NAMES:
		_cache[n] = _build(n)

func _setup_bus() -> void:
	_bus_idx = AudioServer.get_bus_index("Sfx")
	if _bus_idx == -1:
		AudioServer.add_bus()
		_bus_idx = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(_bus_idx, "Sfx")
		AudioServer.set_bus_send(_bus_idx, "Master")
	# Bien por debajo de la música: los efectos acompañan, no mandan.
	AudioServer.set_bus_volume_db(_bus_idx, -11.0)

## Reproduce un efecto. pitch_var mete una pequeña variación de tono al vuelo
## para que repetir la misma acción no suene a ametralladora.
func play(sound: String, pitch_var: float = 0.05) -> void:
	if not _cache.has(sound):
		return
	var stream: AudioStreamWAV = _cache[sound]
	if stream == null or _players.is_empty():
		return
	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = stream
	p.pitch_scale = 1.0 + randf_range(-pitch_var, pitch_var)
	p.play()

## ---------- SÍNTESIS ----------

## Oscilador con barrido de tono y envolvente de ataque + caída exponencial.
func _osc(buf: PackedFloat32Array, at: float, dur: float, f0: float, f1: float,
		wave: String, vol: float, decay: float, attack: float = 0.004) -> void:
	var start := int(at * RATE)
	var n := int(dur * RATE)
	if n <= 0:
		return
	var phase := 0.0
	for i in range(n):
		var idx := start + i
		if idx < 0 or idx >= buf.size():
			continue
		var t := float(i) / float(RATE)
		var u := float(i) / float(max(1, n - 1))
		phase += lerp(f0, f1, u) / float(RATE)
		var ph := fmod(phase, 1.0)
		var s := 0.0
		match wave:
			"square": s = 1.0 if ph < 0.5 else -1.0
			"pulse": s = 1.0 if ph < 0.25 else -1.0
			"saw": s = ph * 2.0 - 1.0
			"tri": s = abs(ph * 4.0 - 2.0) - 1.0
			_: s = sin(ph * TAU)
		var env: float = min(1.0, t / max(attack, 0.0001)) * exp(-t * decay)
		buf[idx] += s * env * vol

## Ruido con un filtro paso bajo que se abre o se cierra durante el sonido. Es
## lo que convierte el mismo ruido en un roce de carta, un golpe o una
## explosión, según cómo se mueva el filtro.
func _noise(buf: PackedFloat32Array, at: float, dur: float, vol: float, decay: float,
		lp0: float = 0.3, lp1: float = 0.3, attack: float = 0.001) -> void:
	var start := int(at * RATE)
	var n := int(dur * RATE)
	if n <= 0:
		return
	var last := 0.0
	for i in range(n):
		var idx := start + i
		if idx < 0 or idx >= buf.size():
			continue
		var t := float(i) / float(RATE)
		var u := float(i) / float(max(1, n - 1))
		last = lerp(last, randf_range(-1.0, 1.0), lerp(lp0, lp1, u))
		var env: float = min(1.0, t / max(attack, 0.0001)) * exp(-t * decay)
		buf[idx] += last * env * vol

## Ruido en PASO ALTO: se le resta al ruido su propia versión filtrada, lo que
## deja sólo la parte aguda. Es la diferencia entre un soplo y el roce seco de
## una carta de cartón.
func _paper(buf: PackedFloat32Array, at: float, dur: float, vol: float, decay: float,
		lp: float = 0.5, attack: float = 0.002) -> void:
	var start := int(at * RATE)
	var n := int(dur * RATE)
	var last := 0.0
	for i in range(n):
		var idx := start + i
		if idx < 0 or idx >= buf.size():
			continue
		var t := float(i) / float(RATE)
		var raw := randf_range(-1.0, 1.0)
		last = lerp(last, raw, lp)
		var env: float = min(1.0, t / max(attack, 0.0001)) * exp(-t * decay)
		buf[idx] += (raw - last) * env * vol

## Soplo: la amplitud sube y baja en forma de campana en vez de golpear y caer.
## Eso es lo que separa una llamarada de una explosión.
func _whoosh(buf: PackedFloat32Array, at: float, dur: float, vol: float,
		lp0: float, lp1: float, high_pass: bool = false) -> void:
	var start := int(at * RATE)
	var n := int(dur * RATE)
	var last := 0.0
	for i in range(n):
		var idx := start + i
		if idx < 0 or idx >= buf.size():
			continue
		var u := float(i) / float(max(1, n - 1))
		var raw := randf_range(-1.0, 1.0)
		last = lerp(last, raw, lerp(lp0, lp1, u))
		var s: float = (raw - last) if high_pass else last
		buf[idx] += s * pow(sin(u * PI), 1.4) * vol

## Golpe sobre madera: tres parciales INARMÓNICOS que se apagan enseguida. Los
## armónicos exactos suenan a nota musical; los inarmónicos, a objeto sólido.
func _knock(buf: PackedFloat32Array, at: float, freq: float, vol: float, decay: float = 34.0) -> void:
	_osc(buf, at, 0.14, freq, freq * 0.92, "sine", vol, decay, 0.0008)
	_osc(buf, at, 0.10, freq * 2.37, freq * 2.2, "sine", vol * 0.45, decay * 1.6, 0.0008)
	_osc(buf, at, 0.07, freq * 4.1, freq * 3.8, "sine", vol * 0.22, decay * 2.4, 0.0008)
	_noise(buf, at, 0.018, vol * 0.4, 130.0, 0.5, 0.2)

## Campana: los parciales de una campana de verdad (1, 2.76, 5.4, 8.9), que no
## son múltiplos enteros y por eso suena a metal y no a flauta.
func _bell(buf: PackedFloat32Array, at: float, dur: float, freq: float, vol: float) -> void:
	var ratios := [1.0, 2.76, 5.40, 8.93]
	var vols := [1.0, 0.55, 0.32, 0.18]
	for k in range(ratios.size()):
		_osc(buf, at, dur, freq * ratios[k], freq * ratios[k], "sine", vol * vols[k], 2.2 + k * 1.2, 0.002)

## Instrumento de viento: armónicos exactos con ataque LENTO. El ataque es lo
## que hace que suene soplado en vez de golpeado.
func _horn(buf: PackedFloat32Array, at: float, dur: float, freq: float, vol: float,
		decay: float = 3.0) -> void:
	_osc(buf, at, dur, freq, freq, "sine", vol, decay, 0.045)
	_osc(buf, at, dur, freq * 2.0, freq * 2.0, "sine", vol * 0.55, decay * 1.1, 0.050)
	_osc(buf, at, dur, freq * 3.0, freq * 3.0, "sine", vol * 0.30, decay * 1.3, 0.055)
	_osc(buf, at, dur, freq * 4.0, freq * 4.0, "sine", vol * 0.14, decay * 1.5, 0.060)

## Cuerda pulsada (Karplus-Strong): se llena un anillo del largo de un periodo
## con ruido y se va promediando consigo mismo. El ruido inicial es la púa y el
## promediado se come los agudos igual que hace una cuerda de verdad, así que
## sale un laúd sin tener que grabar ninguno.
func _pluck(buf: PackedFloat32Array, at: float, dur: float, freq: float, vol: float,
		damp: float = 0.995, bright: float = 0.5) -> void:
	var period := int(round(float(RATE) / max(freq, 20.0)))
	if period < 2:
		return
	var ring := PackedFloat32Array()
	ring.resize(period)
	var last := 0.0
	var peak := 0.0
	for i in range(period):
		last = lerp(last, randf_range(-1.0, 1.0), bright)
		ring[i] = last
		peak = max(peak, abs(last))
	# La púa se normaliza a fondo de escala. Sin esto la amplitud depende del
	# brillo (un filtrado fuerte deja el ruido inicial en nada) y `vol` deja de
	# significar nada: era lo que dejaba la fanfarria de victoria más floja que
	# un clic de botón.
	if peak > 0.0001:
		for i in range(period):
			ring[i] = ring[i] / peak
	var start := int(at * RATE)
	var n := int(dur * RATE)
	var r := 0
	for i in range(n):
		var cur: float = ring[r]
		ring[r] = (cur + ring[(r + 1) % period]) * 0.5 * damp
		r = (r + 1) % period
		var idx := start + i
		if idx >= 0 and idx < buf.size():
			buf[idx] += cur * vol

func _new_buf(dur: float) -> PackedFloat32Array:
	var buf := PackedFloat32Array()
	buf.resize(int(dur * RATE))
	buf.fill(0.0)
	return buf

func _to_stream(buf: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(buf.size() * 2)
	for i in range(buf.size()):
		# Saturar en vez de dejar que dé la vuelta: un desbordamiento aquí
		# suena a chasquido roto, no a distorsión.
		var v: float = clamp(buf[i], -1.0, 1.0)
		bytes.encode_s16(i * 2, int(round(v * 32767.0)))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	return wav

## ---------- RECETAS ----------

func _build(sound: String) -> AudioStreamWAV:
	var buf: PackedFloat32Array
	match sound:
		"click":
			# Botón: nudillo sobre la mesa de la taberna.
			buf = _new_buf(0.18)
			_knock(buf, 0.0, 205.0, 0.21, 32.0)

		"card":
			# Tocar una carta: roce de cartón con un poco de cuerpo grave.
			buf = _new_buf(0.13)
			_paper(buf, 0.0, 0.055, 0.30, 52.0, 0.55)
			_osc(buf, 0.0, 0.08, 128.0, 108.0, "sine", 0.10, 44.0, 0.001)

		"draw":
			# Robar: la carta se desliza y se separa del montón. Soplo en paso
			# alto, sin nota ninguna: es puro roce.
			buf = _new_buf(0.26)
			_whoosh(buf, 0.0, 0.20, 0.42, 0.30, 0.80, true)
			_paper(buf, 0.16, 0.05, 0.16, 45.0, 0.6)

		"place":
			# Posar la carta en la madera: el papel primero y el golpe después.
			buf = _new_buf(0.22)
			_paper(buf, 0.0, 0.05, 0.24, 58.0, 0.5)
			_knock(buf, 0.004, 152.0, 0.21, 38.0)

		"flip":
			# Voltear: chasquido seco de cartón.
			buf = _new_buf(0.13)
			_paper(buf, 0.0, 0.07, 0.62, 42.0, 0.62)

		"shuffle":
			# Barajar: una ristra de roces desiguales, como cuando se mezcla de
			# verdad y ninguna carta cae en el mismo momento.
			buf = _new_buf(0.95)
			for k in range(14):
				_paper(buf, k * 0.055 + randf() * 0.012, 0.05, randf_range(0.30, 0.46), 44.0, 0.6)
			_whoosh(buf, 0.0, 0.9, 0.13, 0.30, 0.55, true)

		"burn":
			# Quemar carta: LLAMARADA, no explosión. Nada de golpe seco ni de
			# nota grave; sólo aire caliente que sube y baja y el crepitar del
			# cartón prendiendo.
			buf = _new_buf(1.0)
			_whoosh(buf, 0.0, 0.75, 0.52, 0.80, 0.10, false)
			_whoosh(buf, 0.0, 0.40, 0.22, 0.45, 0.90, true)
			for k in range(24):
				_paper(buf, 0.02 + randf() * 0.65, 0.012, randf_range(0.10, 0.24), 140.0, 0.75)

		"burn_fail":
			# Fallar: golpe sordo y dos notas de laúd apagadas que bajan. Suena
			# a decepción, no a error de máquina recreativa.
			buf = _new_buf(0.6)
			_knock(buf, 0.0, 118.0, 0.24, 24.0)
			_pluck(buf, 0.04, 0.45, 146.83, 0.17, 0.988, 0.30)
			_pluck(buf, 0.17, 0.38, 138.59, 0.14, 0.986, 0.30)

		"dutch":
			# Cantar Dutch: toque de cuerno de tres notas. El ataque lento es
			# lo que lo hace sonar soplado.
			buf = _new_buf(1.1)
			var horn := [293.66, 392.0, 493.88]
			for k in range(horn.size()):
				_horn(buf, k * 0.15, 0.75, horn[k], 0.16, 2.6)

		"turn":
			# Te toca: dos notas de laúd, cortas y claras.
			buf = _new_buf(0.6)
			_pluck(buf, 0.0, 0.4, 587.33, 0.26, 0.991, 0.5)
			_pluck(buf, 0.10, 0.45, 880.0, 0.22, 0.991, 0.5)

		"chime":
			# Efecto del 10: campanilla de metal.
			buf = _new_buf(1.0)
			_bell(buf, 0.0, 0.95, 1046.5, 0.15)

		"swap":
			# Efecto del 11: dos corrientes de aire que se cruzan.
			buf = _new_buf(0.55)
			_whoosh(buf, 0.0, 0.30, 0.26, 0.20, 0.75, true)
			_whoosh(buf, 0.15, 0.30, 0.26, 0.75, 0.20, true)

		"win":
			# Victoria: arpegio de laúd que sube, con un cuerno sosteniendo por
			# debajo. Las cuerdas siguen sonando unas sobre otras, que es lo que
			# da el aire de taberna en fiesta.
			buf = _new_buf(2.2)
			var up := [392.0, 523.25, 659.25, 783.99, 1046.5]
			for k in range(up.size()):
				_pluck(buf, k * 0.13, 1.7, up[k], 0.32, 0.9965, 0.45)
			_horn(buf, 0.55, 1.3, 392.0, 0.20, 1.5)

		"lose":
			# Derrota: el mismo laúd bajando en menor, más lento, y un cuerno
			# grave sosteniendo al final.
			buf = _new_buf(2.2)
			var down := [523.25, 440.0, 349.23, 261.63]
			for k in range(down.size()):
				_pluck(buf, k * 0.19, 1.6, down[k], 0.32, 0.9955, 0.35)
			_horn(buf, 0.62, 1.2, 130.81, 0.22, 1.4)

		_:
			buf = _new_buf(0.05)
	return _to_stream(buf)
