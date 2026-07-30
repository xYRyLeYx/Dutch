extends Node
## Autoload: CardData
## Baraja española (40 cartas): 1-7, 10, 11, 12 en 4 palos.
## Card is represented as a String id: "<suit>-<number>", e.g. "oros-12"

const SUITS: Array[String] = ["oros", "copas", "espadas", "bastos"]
const NUMBERS: Array[int] = [1, 2, 3, 4, 5, 6, 7, 10, 11, 12]

static func make_id(suit: String, number: int) -> String:
	return "%s-%d" % [suit, number]

static func parse_suit(card_id: String) -> String:
	return card_id.split("-")[0]

static func parse_number(card_id: String) -> int:
	return int(card_id.split("-")[1])

## Point value of a card for end-of-round scoring.
## 12 of espadas/oros = 0 points. 12 of bastos/copas = 30 points.
## Everything else (1-7, 10, 11) is worth its own number.
static func card_value(card_id: String) -> int:
	var suit := parse_suit(card_id)
	var number := parse_number(card_id)
	if number == 12:
		if suit == "espadas" or suit == "oros":
			return 0
		return 30
	return number

static func build_deck() -> Array[String]:
	var deck: Array[String] = []
	for suit in SUITS:
		for number in NUMBERS:
			deck.append(make_id(suit, number))
	return deck

static func shuffle_deck(deck: Array[String]) -> Array[String]:
	var d := deck.duplicate()
	d.shuffle()
	return d
