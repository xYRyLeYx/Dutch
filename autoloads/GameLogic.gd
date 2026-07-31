extends Node
## Autoload: GameLogic
## Authoritative rules engine. Only the HOST (peer id 1) ever calls the
## mutating functions here. Every time state changes, `state_changed` fires;
## NetworkManager listens to that and broadcasts the new state to all peers.
##
## This is a straight port of the rules validated in the web prototype:
## - 4 cards each, peek 2 at the start, never see them again.
## - On your turn: draw from deck or discard, then swap into a hand slot
##   or discard the drawn card directly.
## - Burn: anytime, any player may try to discard a card matching the
##   current discard top's number. Wrong guess = 1 penalty card drawn.
## - 10 discarded -> peek one of your OWN cards (not an opponent's).
## - 11 discarded -> forced blind swap between one of your cards and one
##   of an opponent's (neither sees the values).
## - 12: espadas/oros = 0 pts, bastos/copas = 30 pts. Others = face value.
## - "Dutch": declared at the start of a turn instead of drawing, only once
##   at least MIN_DUTCH_ROUND full laps have passed (stops early rushes to
##   end the game). One more full lap, then reveal + score. Lowest wins.
## - Emptying your hand via burns ends the game immediately (you win).

signal state_changed

var state: Dictionary = {}

## Contador de eventos visuales. Cada acción que la interfaz debe *animar*
## (una carta que vuela, un intercambio, una quemada fallida) deja constancia
## en state.fx; como viaja dentro del estado, los clientes ven exactamente los
## mismos movimientos que el anfitrión sin necesidad de RPCs aparte. La UI
## compara `seq` con el último que reprodujo para no repetir animaciones al
## redibujar.
var _fx_seq: int = 0

func _fx(kind: String, data: Dictionary = {}) -> void:
	_fx_seq += 1
	data["kind"] = kind
	data["seq"] = _fx_seq
	state["fx"] = data

## How long (ms) everyone gets to try a burn after a card lands on the
## discard pile before the next draw is allowed. This is the actual fix for
## "turns end too fast to react" — nobody (bot or human) can draw during
## this window, no matter whose turn it is.
const BURN_WINDOW_MS: int = 4000

## Duración real de esa ventana. Es variable y no constante porque el tutorial
## la acorta: allí no hay nadie compitiendo por quemar, y esperar cuatro
## segundos con el botón de robar en gris parece que el juego se ha colgado.
var burn_window_ms: int = BURN_WINDOW_MS

## Nobody may say "Dutch" before this many full laps have happened, so a
## player can't end the game after a single unlucky round just to be
## annoying. Round 1 is everyone's first turn; round 4 means at least
## 3 full laps have already completed.
const MIN_DUTCH_ROUND: int = 4

func reset_lobby(host_peer_id: int, host_name: String) -> void:
	state = {
		"status": "lobby",
		"players": [
			_new_player(host_peer_id, host_name)
		],
		"host_id": host_peer_id,
		"deck": [],
		"discard": [],
		"turn_index": 0,
		"round_number": 1,
		"active_draw": {},
		"pending_special": {},
		"burn_deadline_ms": 0,
		"dutch_caller_id": -1,
		"results": {},
		"fx": {},
		"discard_burned": false,
		"log": ["%s creó la sala." % host_name],
	}
	state_changed.emit()

## `bot` marca a los jugadores que mueve el anfitrión. Viaja dentro del estado
## como cualquier otra cosa, así que el resto de la mesa también sabe quién es
## bot y puede indicarlo en pantalla.
func _new_player(peer_id: int, name: String, is_bot: bool = false) -> Dictionary:
	return {
		"id": peer_id,
		"name": name,
		"hand": [],
		"peeked_idx": [],
		"ready_peek": false,
		"bot": is_bot,
		# Listo EN LA SALA DE ESPERA, que no es lo mismo que ready_peek (ése es
		# el de después, cuando ya has mirado tus dos cartas). Los bots nacen
		# listos: no tienen a nadie a quien esperar.
		"ready_lobby": is_bot,
	}

func _find_player(peer_id: int) -> Dictionary:
	for p in state.players:
		if p.id == peer_id:
			return p
	return {}

func _push_log(text: String) -> void:
	state.log.append(text)
	if state.log.size() > 30:
		state.log = state.log.slice(state.log.size() - 30)

## ---------- LOBBY ----------

func add_player(peer_id: int, name: String, is_bot: bool = false) -> bool:
	if state.get("status", "") != "lobby":
		return false
	if state.players.size() >= NetworkManager.MAX_PLAYERS:
		return false
	if not _find_player(peer_id).is_empty():
		return false
	state.players.append(_new_player(peer_id, name, is_bot))
	_push_log("%s se unió a la sala." % name)
	state_changed.emit()
	return true

func remove_player(peer_id: int) -> bool:
	for i in range(state.get("players", []).size()):
		if state.players[i].id == peer_id:
			var name: String = str(state.players[i].name)
			state.players.remove_at(i)
			_push_log("%s salió de la sala." % name)
			state_changed.emit()
			return true
	return false

## ---------- BOTS EN LA SALA ----------
##
## Para no tener que ser cuatro amigos: el anfitrión rellena los huecos que
## falten con bots. Un bot es un jugador normal con la marca `bot`; quien los
## mueve es el anfitrión, y para el resto de la mesa son indistinguibles.

func add_bot(requester_id: int, name: String) -> bool:
	if requester_id != state.get("host_id", -1) or state.get("status", "") != "lobby":
		return false
	# Identificador libre por encima de los que reparte el relé, para que no
	# pueda chocar con el de un jugador que entre después.
	var id: int = NetworkManager.BOT_BASE_ID
	while not _find_player(id).is_empty():
		id += 1
	return add_player(id, name, true)

func remove_bot(requester_id: int) -> bool:
	if requester_id != state.get("host_id", -1) or state.get("status", "") != "lobby":
		return false
	for i in range(state.players.size() - 1, -1, -1):
		if bool(state.players[i].get("bot", false)):
			return remove_player(state.players[i].id)
	return false

## Un humano que se ha caído a mitad de partida pasa a jugarlo un bot. No se le
## puede echar sin más: sus cartas cuentan para el recuento y la ronda se
## quedaría esperándole eternamente.
func make_bot(peer_id: int) -> bool:
	var p := _find_player(peer_id)
	if p.is_empty() or bool(p.get("bot", false)):
		return false
	p.bot = true
	# Se le da por listo aunque se cayera antes de mirar sus cartas: si no, la
	# fase de mirar se quedaría esperando a alguien que ya no está.
	p.ready_peek = true
	_maybe_advance_from_peek()
	_push_log("%s se desconectó; le sustituye un bot." % p.name)
	state_changed.emit()
	return true

## ---------- "ESTOY LISTO" DE LA SALA DE ESPERA ----------
##
## Sin esto, el anfitrión reparte cuando le apetece y a los demás les puede
## pillar leyendo las reglas o sin haber terminado de sentarse. Ahora cada
## invitado avisa de que está, y hasta entonces el botón de empezar no se
## enciende.
##
## El anfitrión no marca nada: su "estoy listo" es pulsar "Iniciar partida".

func set_lobby_ready(peer_id: int, ready: bool) -> bool:
	if state.get("status", "") != "lobby":
		return false
	var p := _find_player(peer_id)
	if p.is_empty() or peer_id == state.get("host_id", -1):
		return false
	if bool(p.get("ready_lobby", false)) == ready:
		return false
	p.ready_lobby = ready
	_push_log("%s %s." % [p.name, "está listo" if ready else "ya no está listo"])
	state_changed.emit()
	return true

## A quién se está esperando todavía. Devuelve nombres y no un simple sí/no
## para que la sala pueda decir a quién, que es la información que de verdad
## hace falta cuando la partida no arranca.
func lobby_pending_names() -> Array:
	var pending: Array = []
	for p in state.get("players", []):
		if p.id == state.get("host_id", -1):
			continue
		if not bool(p.get("ready_lobby", false)):
			pending.append(str(p.name))
	return pending

func start_game(requester_id: int) -> bool:
	if requester_id != state.host_id:
		return false
	if state.players.size() < 2:
		return false
	if not lobby_pending_names().is_empty():
		return false
	var deck: Array[String] = CardData.shuffle_deck(CardData.build_deck())
	for p in state.players:
		p.hand = deck.slice(0, 4)
		deck = deck.slice(4)
		p.peeked_idx = []
		p.ready_peek = false
	state.deck = deck
	_fresh_round_state()
	_push_log("La partida ha comenzado. ¡A mirar vuestras cartas!")
	state_changed.emit()
	return true

## Reparto TRUCADO, sólo para el tutorial: en vez de barajar, se colocan las
## manos y el mazo tal cual llegan. Es lo que permite que el guion sepa de
## antemano qué carta va a salir en cada momento y pueda pedir cosas concretas
## ("cambia la que robas por tu segunda carta") en vez de generalidades.
##
## `hands` es una mano por jugador, en el mismo orden que state.players.
func start_scripted_game(requester_id: int, hands: Array, deck: Array) -> bool:
	if requester_id != state.host_id:
		return false
	if hands.size() < state.players.size():
		return false
	for i in range(state.players.size()):
		var p: Dictionary = state.players[i]
		p.hand = _as_string_array(hands[i])
		p.peeked_idx = []
		p.ready_peek = false
	state.deck = _as_string_array(deck)
	_fresh_round_state()
	_push_log("Partida de práctica. ¡A mirar vuestras cartas!")
	state_changed.emit()
	return true

## Deja el estado como "recién repartido", sin tocar las manos ni el mazo: eso
## es lo único que cambia entre una partida normal, una revancha y el reparto
## trucado del tutorial.
func _fresh_round_state() -> void:
	state.discard = []
	state.status = "peek"
	state.turn_index = 0
	state.round_number = 1
	state.active_draw = {}
	state.burn_deadline_ms = 0
	state.pending_special = {}
	state.dutch_caller_id = -1
	state.results = {}
	state.fx = {}
	state.discard_burned = false

## ---------- PEEK PHASE ----------

func player_peek(peer_id: int, idx: int) -> bool:
	var p := _find_player(peer_id)
	if p.is_empty() or p.ready_peek:
		return false
	if p.peeked_idx.size() >= 2 or p.peeked_idx.has(idx):
		return false
	p.peeked_idx.append(idx)
	state_changed.emit()
	return true

func player_ready(peer_id: int) -> bool:
	var p := _find_player(peer_id)
	if p.is_empty() or p.peeked_idx.size() < 2:
		return false
	p.ready_peek = true
	_push_log("%s está listo." % p.name)
	_maybe_advance_from_peek()
	state_changed.emit()
	return true

func _maybe_advance_from_peek() -> void:
	if state.status != "peek":
		return
	for p in state.players:
		if not p.ready_peek:
			return
	state.status = "playing"
	_push_log("Todos listos. ¡Empieza la partida!")

## ---------- TURN HELPERS ----------

## Marca si la última extracción obligó a rehacer el mazo, para que la
## interfaz pueda sonar a barajar en ese momento.
var _did_reshuffle: bool = false

## Copia a un Array[String] de verdad, elemento a elemento.
##
## Los arrays que viven dentro de `state` NO llevan tipo: nacen como [] dentro
## del diccionario y, en online, vuelven del JSON igual de pelados. Pasar uno
## de esos a algo que espera Array[String] no es un aviso, es un error EN
## TIEMPO DE EJECUCIÓN que aborta la función a media faena. Eso es exactamente
## lo que impedía rehacer el mazo: la línea del slice reventaba, el mazo nunca
## se rebarajaba y la partida se quedaba colgada al agotarse la baraja.
func _as_string_array(src: Array) -> Array[String]:
	var out: Array[String] = []
	for v in src:
		out.append(str(v))
	return out

func _draw_one_from_deck() -> String:
	_did_reshuffle = false
	if state.deck.is_empty():
		# Se rehace el mazo con el descarte, salvo la carta de arriba: esa se
		# queda a la vista porque es la que hay que emparejar para quemar.
		if state.discard.size() <= 1:
			return ""
		var top: String = str(state.discard[-1])
		var rest := _as_string_array(state.discard.slice(0, state.discard.size() - 1))
		state.deck = CardData.shuffle_deck(rest)
		state.discard = [top]
		_did_reshuffle = true
		_push_log("Se barajó el descarte para formar un mazo nuevo.")
	if state.deck.is_empty():
		return ""
	var card: String = state.deck[0]
	state.deck.remove_at(0)
	return card

## ¿Puede el mazo servir una carta? Directamente, o rehaciéndose con el
## descarte (hace falta que sobre alguna además de la de arriba, que se queda
## a la vista).
func deck_can_serve() -> bool:
	return not state.deck.is_empty() or state.discard.size() >= 2

## ¿Queda alguna forma de robar? Del mazo, o del descarte si no está quemado.
## Si no hay ninguna, la partida no puede continuar.
func can_draw_anything() -> bool:
	if deck_can_serve():
		return true
	return not state.discard.is_empty() and not discard_is_burned()

func _end_game_out_of_cards() -> void:
	_push_log("No quedan cartas ni en el mazo ni en el descarte. ¡Fin de la partida!")
	_end_game(-1)

func _is_current_turn(peer_id: int) -> bool:
	return state.status == "playing" and state.players[state.turn_index].id == peer_id

func _advance_turn() -> void:
	var next_index: int = (state.turn_index + 1) % state.players.size()
	if state.dutch_caller_id != -1 and state.players[next_index].id == state.dutch_caller_id:
		_end_game(-1)
		return
	if next_index == 0:
		state.round_number += 1
	state.turn_index = next_index
	# Se comprueba AL EMPEZAR el turno, no al intentar robar: así la partida
	# termina en el momento en que deja de poder jugarse, en vez de dejar al
	# siguiente jugador pulsando un botón que no hace nada.
	if not can_draw_anything():
		_end_game_out_of_cards()

func _end_game(auto_winner_id: int) -> void:
	state.status = "ended"
	var rows: Array = []
	for p in state.players:
		var total := 0
		for c in p.hand:
			total += CardData.card_value(c)
		rows.append({"id": p.id, "name": p.name, "hand": p.hand.duplicate(), "total": total})
	var min_total: int = 999999
	for r in rows:
		if r.total < min_total:
			min_total = r.total
	var winner_ids: Array = []
	if auto_winner_id != -1:
		winner_ids = [auto_winner_id]
	else:
		for r in rows:
			if r.total == min_total:
				winner_ids.append(r.id)
	state.results = {"rows": rows, "winner_ids": winner_ids}
	if auto_winner_id != -1:
		_push_log("%s se quedó sin cartas. ¡Fin de la partida!" % _find_player(auto_winner_id).name)
	else:
		_push_log("Se completó la vuelta del Dutch. ¡Fin de la partida!")

## Resolves what happens after any card lands on top of the discard pile:
## checks for an empty-hand win, then for 10/11 special effects, otherwise
## advances the turn (only when this came from a normal turn action).
func _resolve_discard_top_effects(actor_id: int, advance_after: bool) -> void:
	state.burn_deadline_ms = Time.get_ticks_msec() + burn_window_ms
	var actor := _find_player(actor_id)
	if not actor.is_empty() and actor.hand.is_empty():
		_end_game(actor_id)
		return
	var top: String = state.discard[-1]
	var number := CardData.parse_number(top)
	if number == 10:
		state.pending_special = {"type": "10", "by": actor_id, "advance_after": advance_after}
		return
	if number == 11:
		state.pending_special = {"type": "11", "by": actor_id, "advance_after": advance_after, "target_id": -1, "my_slot": -1, "target_slot": -1}
		return
	if advance_after:
		_advance_turn()

## ---------- DRAW / SWAP / DISCARD ----------

## True while the reaction window after a discard is still open — nobody
## may draw during this time, which is what gives everyone a real chance to
## burn instead of the turn racing ahead the instant a card lands.
func burn_window_active() -> bool:
	return Time.get_ticks_msec() < state.get("burn_deadline_ms", 0)

func burn_window_remaining_ms() -> int:
	return max(0, state.get("burn_deadline_ms", 0) - Time.get_ticks_msec())

func draw_from_deck(peer_id: int) -> bool:
	if not _is_current_turn(peer_id) or not state.active_draw.is_empty() or not state.pending_special.is_empty() or burn_window_active():
		return false
	var card := _draw_one_from_deck()
	if card == "":
		# Sólo se acaba la partida si TAMPOCO se puede robar del descarte: con
		# el mazo seco pero una carta robable en la mesa, la partida sigue.
		if not can_draw_anything():
			_end_game_out_of_cards()
			state_changed.emit()
		return false
	state.active_draw = {"player_id": peer_id, "card": card, "source": "deck"}
	_fx("draw", {"actor": peer_id, "source": "deck", "reshuffled": _did_reshuffle})
	state_changed.emit()
	return true

## Una carta QUEMADA se queda en el descarte a la vista, pero ya no se puede
## robar: sólo sirve para que otros sigan quemando encima si tienen su mismo
## número. El descarte vuelve a estar disponible en cuanto alguien tira una
## carta de forma normal.
func discard_is_burned() -> bool:
	return state.get("discard_burned", false)

func draw_from_discard(peer_id: int) -> bool:
	if not _is_current_turn(peer_id) or not state.active_draw.is_empty() or not state.pending_special.is_empty() or burn_window_active():
		return false
	if state.discard.is_empty() or discard_is_burned():
		return false
	var card: String = state.discard[-1]
	state.discard.remove_at(state.discard.size() - 1)
	state.active_draw = {"player_id": peer_id, "card": card, "source": "discard"}
	_fx("draw", {"actor": peer_id, "source": "discard", "card": card})
	state_changed.emit()
	return true

func resolve_swap(peer_id: int, idx: int) -> bool:
	if state.active_draw.is_empty() or state.active_draw.player_id != peer_id:
		return false
	var p := _find_player(peer_id)
	if idx < 0 or idx >= p.hand.size():
		return false
	var old_card: String = p.hand[idx]
	p.hand[idx] = state.active_draw.card
	state.discard.append(old_card)
	# Carta puesta de forma normal: el descarte vuelve a poder robarse.
	state.discard_burned = false
	_push_log("%s cambió una carta y descartó." % p.name)
	_fx("swap", {"actor": peer_id, "slot": idx, "card": old_card})
	state.active_draw = {}
	_resolve_discard_top_effects(peer_id, true)
	state_changed.emit()
	return true

func resolve_discard_drawn(peer_id: int) -> bool:
	if state.active_draw.is_empty() or state.active_draw.player_id != peer_id:
		return false
	var p := _find_player(peer_id)
	var thrown: String = state.active_draw.card
	state.discard.append(thrown)
	state.discard_burned = false
	_push_log("%s descartó la carta robada." % p.name)
	_fx("discard", {"actor": peer_id, "card": thrown, "from": "drawn"})
	state.active_draw = {}
	_resolve_discard_top_effects(peer_id, true)
	state_changed.emit()
	return true

## ---------- BURN ----------

func attempt_burn(peer_id: int, idx: int) -> bool:
	if state.discard.is_empty() or not state.pending_special.is_empty():
		return false
	var p := _find_player(peer_id)
	if p.is_empty() or idx < 0 or idx >= p.hand.size():
		return false
	var top_card: String = state.discard[-1]
	var my_card: String = p.hand[idx]
	var top_number := CardData.parse_number(top_card)
	var my_number := CardData.parse_number(my_card)
	if top_number == my_number:
		# Correct: the card actually leaves your hand and lands on the
		# discard pile, same as a normal discard.
		p.hand.remove_at(idx)
		state.discard.append(my_card)
		# A partir de aquí el descarte está quemado: nadie puede robarlo, pero
		# sigue admitiendo más quemadas del mismo número.
		state.discard_burned = true
		_push_log("%s quemó correctamente un %d." % [p.name, my_number])
		_fx("burn_ok", {"actor": peer_id, "card": my_card, "slot": idx})
		_resolve_discard_top_effects(peer_id, false)
	else:
		# Wrong: you keep the card you tried to burn (it was never actually
		# discarded) AND draw one extra penalty card, so a failed attempt
		# costs you a net +1 card, not a net 0 swap.
		var penalty := _draw_one_from_deck()
		if penalty != "":
			p.hand.append(penalty)
		_push_log("%s falló al quemar (intentó un %d) y recibió una carta de penalización." % [p.name, my_number])
		_fx("burn_fail", {"actor": peer_id, "slot": idx})
	state_changed.emit()
	return true

## ---------- DUTCH ----------

func call_dutch(peer_id: int) -> bool:
	if not _is_current_turn(peer_id) or not state.active_draw.is_empty() or not state.pending_special.is_empty() or state.dutch_caller_id != -1:
		return false
	if state.get("round_number", 1) < MIN_DUTCH_ROUND:
		return false
	state.dutch_caller_id = peer_id
	_push_log("%s dijo \"Dutch\" y sigue jugando su turno. ¡Última vuelta!" % _find_player(peer_id).name)
	_fx("dutch", {"actor": peer_id})
	# NO se avanza el turno: cantar Dutch se hace al empezar tu turno y luego
	# lo juegas con normalidad (robas y cambias o descartas). El turno pasa
	# solo cuando termines, como cualquier otro. La partida acaba cuando la
	# vuelta regresa a quien cantó, y de eso ya se encarga _advance_turn().
	state_changed.emit()
	return true

## ---------- SPECIAL: 10 = peek one card ----------

## The 10 only ever lets you refresh your memory of your OWN hand — target_id
## is required to equal peer_id. (Peeking an opponent's card is the 11's job,
## via a blind swap, not the 10's.)
func resolve_ten_pick(peer_id: int, target_id: int, idx: int) -> bool:
	var ps: Dictionary = state.pending_special
	if ps.is_empty() or ps.type != "10" or ps.by != peer_id:
		return false
	if target_id != peer_id:
		return false
	var target := _find_player(target_id)
	if target.is_empty() or idx < 0 or idx >= target.hand.size():
		return false
	ps.peeked_value = target.hand[idx]
	ps.peeked_label = "Tu carta #%d" % (idx + 1)
	_push_log("%s usó el efecto del 10 para mirar una de sus cartas." % _find_player(peer_id).name)
	state_changed.emit()
	return true

func resolve_ten_ack(peer_id: int) -> bool:
	var ps: Dictionary = state.pending_special
	if ps.is_empty() or ps.type != "10" or ps.by != peer_id:
		return false
	var advance: bool = ps.advance_after
	state.pending_special = {}
	state.burn_deadline_ms = Time.get_ticks_msec() + burn_window_ms
	if advance:
		_advance_turn()
	state_changed.emit()
	return true

## ---------- SPECIAL: 11 = forced blind swap ----------

## Quién tiene que elegir AHORA en un 11. Primero decide quien lo jugó (a qué
## rival ataca y qué carta suya se lleva) y después el RIVAL (qué carta se
## lleva de quien jugó el 11). Nadie elige qué carta propia entrega: eso es lo
## que hace que el intercambio sea de verdad a ciegas por ambos lados.
func eleven_actor(ps: Dictionary) -> int:
	if int(ps.get("target_id", -1)) == -1:
		return int(ps.get("by", -1))
	if int(ps.get("target_slot", -1)) == -1:
		return int(ps.get("by", -1))
	return int(ps.get("target_id", -1))

func resolve_eleven_target(peer_id: int, target_id: int) -> bool:
	var ps: Dictionary = state.pending_special
	if ps.is_empty() or ps.type != "11" or ps.by != peer_id:
		return false
	if ps.target_id != -1 or target_id == peer_id:
		return false
	ps.target_id = target_id
	state_changed.emit()
	return true

## Paso 2: quien jugó el 11 señala a ciegas una carta del RIVAL, que es la que
## se lleva.
func resolve_eleven_target_slot(peer_id: int, idx: int) -> bool:
	var ps: Dictionary = state.pending_special
	if ps.is_empty() or ps.type != "11" or ps.by != peer_id:
		return false
	if ps.target_id == -1 or ps.target_slot != -1:
		return false
	var target := _find_player(ps.target_id)
	if target.is_empty() or idx < 0 or idx >= target.hand.size():
		return false
	ps.target_slot = idx
	state_changed.emit()
	return true

## Paso 3, y lo resuelve el RIVAL: señala a ciegas una carta de quien jugó el
## 11. Con las dos elegidas, se hace el intercambio.
func resolve_eleven_my_slot(peer_id: int, idx: int) -> bool:
	var ps: Dictionary = state.pending_special
	if ps.is_empty() or ps.type != "11":
		return false
	if peer_id != ps.target_id or ps.target_slot == -1 or ps.my_slot != -1:
		return false
	var me := _find_player(ps.by)
	var target := _find_player(ps.target_id)
	if me.is_empty() or target.is_empty():
		return false
	if idx < 0 or idx >= me.hand.size():
		return false
	if ps.target_slot >= target.hand.size():
		return false
	ps.my_slot = idx
	var tmp: String = me.hand[idx]
	me.hand[idx] = target.hand[ps.target_slot]
	target.hand[ps.target_slot] = tmp
	_push_log("%s y %s intercambiaron una carta a ciegas." % [me.name, target.name])
	# Ojo con los identificadores: aquí peer_id es el RIVAL, no quien jugó el
	# 11. El vuelo va de la mano de `by` (hueco my_slot) a la del rival (hueco
	# target_slot), que es el intercambio que se acaba de hacer.
	_fx("swap11", {"a": ps.by, "a_slot": ps.my_slot, "b": ps.target_id, "b_slot": ps.target_slot})
	var advance: bool = ps.advance_after
	state.pending_special = {}
	state.burn_deadline_ms = Time.get_ticks_msec() + burn_window_ms
	if advance:
		_advance_turn()
	state_changed.emit()
	return true

## ---------- REMATCH ----------

func play_again(requester_id: int) -> bool:
	if requester_id != state.host_id:
		return false
	var deck: Array[String] = CardData.shuffle_deck(CardData.build_deck())
	for p in state.players:
		p.hand = deck.slice(0, 4)
		deck = deck.slice(4)
		p.peeked_idx = []
		p.ready_peek = false
	state.deck = deck
	_fresh_round_state()
	_push_log("Nueva partida. ¡A mirar vuestras cartas!")
	state_changed.emit()
	return true
