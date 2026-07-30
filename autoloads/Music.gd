extends Node
## Autoload: Music
##
## Reproduce la música en bucle y, de paso, la ANALIZA: monta un bus propio con
## un analizador de espectro y expone la energía de los graves. Eso es lo que
## permite que las llamas, las brasas y las cartas del menú se muevan al ritmo
## de la canción de verdad, en vez de con una animación fija que casualmente
## coincide de vez en cuando.
##
## Si algún día quitas la carpeta music/ o el analizador no está disponible, el
## juego sigue funcionando: se cae a un latido sintético de 120 ppm.

const MUSIC_DIR := "res://music/"
const AUDIO_EXTS := ["mp3", "ogg", "wav"]
const SETTINGS_PATH := "user://settings.cfg"

## Volumen en pasos, que es lo que enseña el mando de la esquina. 0 = callado.
const MAX_LEVEL := 5
var volume_level: int = 4

var _player: AudioStreamPlayer
var _spectrum: AudioEffectSpectrumAnalyzerInstance = null
var _bus_idx: int = -1
var _current_path: String = ""

# Nivel instantáneo de graves, media larga y "golpe". El golpe es la diferencia
# entre el nivel y su media: sube de golpe cuando entra un bombo y decae solo.
var _level: float = 0.0
var _avg: float = 0.0
var _hit: float = 0.0
var _fallback_t: float = 0.0

## Los navegadores no dejan sonar NADA hasta que el usuario toca la pantalla o
## pulsa una tecla. Si se arranca la música antes, el navegador la descarta sin
## avisar y el juego se queda mudo para siempre. Así que en web se prepara la
## pista pero no se lanza hasta el primer gesto. En móvil y escritorio no hay
## tal restricción y suena desde el principio.
var _audio_unlocked: bool = true
var _pending_play: bool = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_bus()
	_load_settings()
	_apply_volume()
	_player = AudioStreamPlayer.new()
	_player.bus = "Music" if _bus_idx != -1 else "Master"
	# Este volumen es el de referencia y NO se toca: el que ajusta el jugador
	# es el del bus, que se aplica después de los efectos. Si se bajara aquí,
	# el analizador de espectro recibiría la señal ya atenuada y las llamas
	# dejarían de bailar al bajar la música.
	_player.volume_db = -8.0
	add_child(_player)
	# Red de seguridad: algunos formatos ignoran el bucle interno, así que si
	# la pista termina se vuelve a lanzar.
	_player.finished.connect(_on_finished)
	if OS.has_feature("web"):
		_audio_unlocked = false
		set_process_input(true)
	play_for("menu")

## Primer gesto del usuario en web: a partir de aquí el navegador ya deja
## sonar, así que se lanza lo que estuviera esperando.
func _input(event: InputEvent) -> void:
	if _audio_unlocked:
		return
	if event is InputEventMouseButton or event is InputEventScreenTouch or event is InputEventKey:
		_audio_unlocked = true
		set_process_input(false)
		if _pending_play and is_instance_valid(_player):
			_pending_play = false
			_player.play()

func _on_finished() -> void:
	if _current_path != "" and is_instance_valid(_player):
		_player.play()

func _setup_bus() -> void:
	_bus_idx = AudioServer.get_bus_index("Music")
	if _bus_idx == -1:
		AudioServer.add_bus()
		_bus_idx = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(_bus_idx, "Music")
		AudioServer.set_bus_send(_bus_idx, "Master")
	if AudioServer.get_bus_effect_count(_bus_idx) == 0:
		var fx := AudioEffectSpectrumAnalyzer.new()
		fx.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
		AudioServer.add_bus_effect(_bus_idx, fx, 0)
	var inst := AudioServer.get_bus_effect_instance(_bus_idx, 0)
	if inst is AudioEffectSpectrumAnalyzerInstance:
		_spectrum = inst

## Busca una pista en music/. Si algún día metes varias, basta con que el
## nombre del archivo contenga "menu" o "partida"/"game" y cada pantalla usará
## la suya; mientras haya una sola, se usa para todo.
func _find_track(kind: String) -> String:
	var dir := DirAccess.open(MUSIC_DIR)
	if dir == null:
		return ""
	var wanted: Array = ["menu"] if kind == "menu" else ["partida", "game", "juego"]
	var found: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			# En el proyecto exportado sólo se ve el .import; se le quita el
			# sufijo para quedarnos con la ruta que entiende load().
			var clean := entry.trim_suffix(".import")
			if AUDIO_EXTS.has(clean.get_extension().to_lower()) and not found.has(MUSIC_DIR + clean):
				found.append(MUSIC_DIR + clean)
		entry = dir.get_next()
	dir.list_dir_end()
	if found.is_empty():
		return ""
	for path in found:
		var lower := path.get_file().to_lower()
		for w in wanted:
			if lower.contains(w):
				return path
	found.sort()
	return found[0]

## kind: "menu" o "game". No reinicia la canción si ya está sonando la misma,
## de forma que la música NO se corta al empezar la partida.
func play_for(kind: String) -> void:
	var path := _find_track(kind)
	if path == "" or path == _current_path:
		return
	if not ResourceLoader.exists(path):
		return
	var stream := load(path)
	if stream == null or not (stream is AudioStream):
		return
	if "loop" in stream:
		stream.loop = true
	_current_path = path
	_player.stream = stream
	if _audio_unlocked:
		_player.play()
	else:
		_pending_play = true

## ---------- VOLUMEN ----------

func set_level(l: int) -> void:
	var clamped: int = clampi(l, 0, MAX_LEVEL)
	if clamped == volume_level:
		return
	volume_level = clamped
	_apply_volume()
	_save_settings()

func _apply_volume() -> void:
	if _bus_idx == -1:
		return
	if volume_level <= 0:
		# -60 dB en vez de silenciar el bus: es inaudible igual, pero deja la
		# señal viva para el analizador, así que el menú sigue animándose
		# aunque hayas quitado la música.
		AudioServer.set_bus_volume_db(_bus_idx, -60.0)
		return
	# Curva con exponente: al oído los pasos salen parejos, cosa que no pasa
	# repartiendo los decibelios en línea recta.
	var lin: float = pow(float(volume_level) / float(MAX_LEVEL), 1.7)
	AudioServer.set_bus_volume_db(_bus_idx, linear_to_db(lin))

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		volume_level = clampi(int(cfg.get_value("audio", "volume_level", MAX_LEVEL - 1)), 0, MAX_LEVEL)

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	# Se carga antes de escribir para no cargarse otros ajustes que haya.
	cfg.load(SETTINGS_PATH)
	cfg.set_value("audio", "volume_level", volume_level)
	cfg.save(SETTINGS_PATH)

func is_playing() -> bool:
	return is_instance_valid(_player) and _player.playing

func _process(delta: float) -> void:
	if _spectrum == null or not is_playing():
		# Latido sintético a 120 ppm para que el menú no se quede quieto.
		_fallback_t += delta
		var phase: float = fmod(_fallback_t, 0.5) / 0.5
		_hit = pow(1.0 - phase, 3.0)
		_level = 0.35 + 0.25 * _hit
		return
	var mag: float = _spectrum.get_magnitude_for_frequency_range(
		30.0, 180.0, AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_MAX).length()
	var lvl: float = clamp((linear_to_db(mag) + 62.0) / 46.0, 0.0, 1.0)
	# Dos suavizados a distinta velocidad: el rápido sigue la música, el lento
	# hace de referencia. Su diferencia es el golpe.
	_level = lerp(_level, lvl, 1.0 - exp(-delta * 14.0))
	_avg = lerp(_avg, _level, 1.0 - exp(-delta * 0.9))
	var raw: float = clamp((_level - _avg) * 4.5, 0.0, 1.0)
	_hit = max(_hit * exp(-delta * 7.0), raw)

## 0..1, sube de golpe con cada pulso grave y decae. Para escalas y destellos.
func beat() -> float:
	return _hit

## 0..1, energía continua de los graves. Para movimientos suaves y sostenidos.
func level() -> float:
	return _level
