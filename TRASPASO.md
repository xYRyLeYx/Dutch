# Dutch — Documento de traspaso

**Versión:** 0.1.0-alpha · **Motor:** Godot 4.7.1 stable · **Fecha:** 30 de julio de 2026

Juego de cartas para móvil basado en el "Dutch" que Cristian y sus amigos juegan
con baraja española. Este documento describe el estado real del proyecto, cómo
está construido, qué está verificado y qué no, y qué hacer a continuación.

---

## 1. Resumen del estado

| Área | Estado |
|---|---|
| Reglas del juego | ✅ Completas y jugables |
| Partida contra bots | ✅ Funciona de principio a fin |
| Arte (pixel art) | ✅ Completo, generado por código |
| Animaciones | ✅ Vuelos de carta, volteos, humo, llamas |
| Audio (música + 14 efectos) | ✅ Sintetizado por código |
| Tutorial guionizado y reglas | ✅ Implementados |
| Exportación Android (APK) | ✅ Firmado y generado |
| Exportación Web | ✅ Generada y arrancada |
| **Multijugador online** | ✅ Funcionando · relé desplegado en Render |
| Exportación iOS (IPA) | ❌ Imposible desde Windows (ver §7) |

**Lo que se puede repartir hoy:** una alpha jugable **contra bots y online**,
tanto en APK como en navegador. El relé está desplegado en
`wss://dutch-relay.onrender.com/` y viene puesto por defecto en el juego, así
que los amigos no tienen que configurar nada.

### Artefactos generados

```
build/dutch-0.1.0-alpha.apk        56,3 MB   firmado, arm64-v8a + armeabi-v7a
build/dutch-web-0.1.0-alpha.zip    14,2 MB   listo para subir a itch.io
```

---

## 2. Cómo abrir y ejecutar el proyecto

- **Ejecutable de Godot:** `F:\Godot_v4.7.1-stable_win64.exe`
  (ojo: está en la unidad F:, no en C:)
- **Carpeta del proyecto:** `C:\Users\Cristian\Downloads\dutch-godot`
- **Escena principal:** `res://scenes/Main.tscn` (un único `Control` con
  `Main.gd`; toda la interfaz se construye por código)

Ejecutar desde línea de comandos:

```bash
"F:\Godot_v4.7.1-stable_win64.exe" --path "C:\Users\Cristian\Downloads\dutch-godot"
```

Exportar sin abrir el editor:

```bash
"F:\Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Android" "build/dutch-0.1.0-alpha.apk"
"F:\Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Web" "build/web/index.html"
```

> **Importante:** cierra el editor antes de exportar por línea de comandos. Los
> ajustes del SDK viven en el archivo de configuración del editor, y si está
> abierto lo sobrescribe al salir.

---

## 3. Arquitectura

### 3.1 Principio general

El juego es **autoritativo en el anfitrión**. Nadie modifica el estado
directamente: todos envían *peticiones* y sólo el anfitrión ejecuta las reglas.

```
Jugador toca la pantalla
   → Main.gd llama a NetworkManager.request_XXX (RPC)
      → sólo el anfitrión ejecuta GameLogic.XXX()
         → GameLogic muta `state` y emite state_changed
            → NetworkManager reparte el estado nuevo (JSON) a todos
               → Main.gd redibuja la pantalla entera
```

Esto significa que **Main.gd no guarda estado de juego**: es una función pura
del diccionario `state`. Cualquier lógica de reglas va en `GameLogic.gd`.

### 3.2 Autoloads (`project.godot` → `[autoload]`)

| Autoload | Archivo | Líneas | Responsabilidad |
|---|---|---|---|
| `CardData` | `autoloads/CardData.gd` | 40 | Baraja española: identificadores `"palo-número"`, valores de puntos |
| `GameLogic` | `autoloads/GameLogic.gd` | 619 | **Todas las reglas.** Único dueño de `state` |
| `NetworkManager` | `autoloads/NetworkManager.gd` | 642 | Peticiones, relé WebSocket y los **bots** (locales y online) |
| `Music` | `autoloads/Music.gd` | 206 | Música en bucle + análisis de espectro |
| `Sfx` | `autoloads/Sfx.gd` | 343 | 14 efectos sintetizados por código |

### 3.3 Escenas y componentes

| Archivo | Líneas | Responsabilidad |
|---|---|---|
| `scenes/Main.gd` | 1748 | Toda la interfaz: menú, sala, mirar cartas, partida, final, modales |
| `scenes/PixelArt.gd` | 780 | **Todo el arte**: cartas, dorsos, fondos, llamas, heráldica |
| `scenes/UI.gd` (`DutchUI`) | 258 | Paleta, tipografías, botones, paneles, tema |
| `scenes/CardView.gd` | 245 | Una carta: dibujo, volteo, elevación, halo, humo |
| `scenes/CardFan.gd` | 56 | Contenedor en abanico que solapa cartas cuando no caben |
| `scenes/TutorialOverlay.gd` | 499 | Tutorial **guionizado**: reparto trucado, 30 pasos, las 3 especiales |
| `scenes/RulesScreen.gd` | 219 | Reglas en texto, paginadas |
| `scenes/VolumeWidget.gd` | 146 | Control de música (altavoz + barra deslizante) |
| `scenes/MenuFx.gd` | 119 | Llamas y brasas del menú, al ritmo de la música |
| `scenes/SmokeFx.gd` | 97 | Humareda al quemar una carta |

### 3.4 El diccionario `state`

Definido en `GameLogic.reset_lobby()`. **Todas sus claves viajan por red como
JSON**, así que sólo contiene tipos serializables.

```gdscript
{
  "status": "lobby" | "peek" | "playing" | "ended",
  "players": [ {id, name, hand[], peeked_idx[], ready_peek} ],
  "host_id": int,
  "deck": [],                # cartas por repartir
  "discard": [],             # la última es la de arriba
  "turn_index": int,
  "round_number": int,
  "active_draw": {},         # {player_id, card, source} mientras alguien decide
  "pending_special": {},     # efecto de 10 u 11 sin resolver
  "burn_deadline_ms": int,   # fin de la ventana para quemar
  "dutch_caller_id": int,    # -1 si nadie ha cantado
  "results": {},             # se rellena al terminar
  "fx": {},                  # último evento visual (ver §3.5)
  "discard_burned": bool,    # el descarte está quemado: no se puede robar
  "log": [],                 # últimas 30 líneas
}
```

### 3.5 El sistema de eventos visuales (`state.fx`)

**Este es el mecanismo clave de las animaciones y conviene entenderlo antes de
tocar nada.**

El problema: cada cambio de estado reconstruye la pantalla entera, así que los
nodos no sobreviven de un render al siguiente y no se puede animar "el mismo"
nodo moviéndose.

La solución: `GameLogic` anota en `state.fx` qué acaba de pasar, con un
contador `seq` incremental. `Main.gd` compara `seq` con el último que
reprodujo; si es nuevo, recrea el movimiento con una **carta de atrezo** que
vuela por encima de todo (`fx_layer`) entre las posiciones reales de los nodos
ya colocados. El nodo de destino se mantiene invisible hasta que la carta
aterriza, así que parece un movimiento continuo.

Como `fx` viaja dentro del estado, **todos los jugadores ven las mismas
animaciones** sin necesidad de RPCs aparte.

Eventos emitidos (`GameLogic._fx(...)`):

| Evento | Datos | Animación en Main.gd |
|---|---|---|
| `draw` | actor, source, reshuffled | Carta vuela del mazo/descarte a la mano |
| `swap` | actor, slot, card | Dos vuelos: la robada entra, la vieja sale |
| `discard` | actor, card, from | Carta vuela al descarte |
| `burn_ok` | actor, card, slot | Vuelo + **humo** + sonido de llamarada |
| `burn_fail` | actor, slot | Carta de castigo + sacudida de la mano |
| `dutch` | actor | Rótulo "DUTCH" a pantalla completa |
| `swap11` | a, a_slot, b, b_slot | Dos cartas se cruzan por el aire |

### 3.6 El registro de anclajes

`Main._anchors` mapea nombres → nodos, y se rehace en cada render. Lo usan **dos
sistemas**: los vuelos de carta y el tutorial guiado (para señalar controles).

Claves registradas: `deck`, `discard`, `drawn`, `hand_row`, `hand_N`,
`seat_<id>`, `mini_<id>_<N>`, `deck_btn`, `discard_btn`, `drop_btn`, `burn_btn`,
`dutch_btn`, `ready_btn`, y los controles de los modales: `modal_burn_N`,
`modal_burn_cancel`, `modal_ten_N`, `modal_ten_ok`, `modal_11_target_<id>`,
`modal_11_take_N`, `modal_11_give_N`.

Desde el tutorial guionizado este registro tiene un **tercer** consumidor: la
restricción de entrada (§3.7). Si añades un control con el que se pueda jugar,
regístralo también, o el tutorial no podrá bloquearlo.

### 3.7 La restricción de entrada del tutorial

`Main.set_input_gate(claves)` deja activos SÓLO los controles de esa lista y
apaga todos los demás del registro. Es lo que hace que el aprendiz no pueda
salirse del guion.

- Las **cartas** se bloquean con `CardView.locked`, que va aparte de
  `interactive` a propósito: así el guion no pisa lo que la partida decidió, y
  al desbloquear no hay que adivinar si la carta era pulsable o no. Una carta
  bloqueada que *sí* sería pulsable se dibuja con un velo oscuro; una que la
  partida ya tenía apagada no, o durante el tutorial la mesa entera saldría en
  penumbra.
- Los **botones** combinan su estado de partida (`_gate_base`, la foto de cómo
  nacieron) con el permiso del guion. Sin esa foto, al cambiar de paso el
  tutorial no sabría distinguir "apagado por el guion" de "apagado por las
  reglas" y acabaría encendiendo botones que no debía.
- `_tick_burn_countdown()` reescribe `disabled` doce veces por segundo, así que
  el permiso del guion **también** se suma allí (`_gate_allows`). Si no, volvería
  a encender lo que el guion había apagado.

`_rect_of(clave)` devuelve el rectángulo global, o `Rect2()` si el nodo ya no
existe o aún no tiene tamaño. `_rect_or_prev(clave)` cae en la foto del render
anterior, necesario para animar movimientos cuyo **origen ya desapareció**
(al descartar la robada, su hueco se borra en el mismo render).

---

## 4. Reglas implementadas

Todas viven en `GameLogic.gd`. Constantes de ajuste:

```gdscript
const BURN_WINDOW_MS: int = 4000   # ventana para quemar tras cada descarte
const MIN_DUTCH_ROUND: int = 4     # ronda mínima para poder cantar Dutch
```

1. **Reparto:** 4 cartas por jugador, boca abajo.
2. **Mirar:** cada uno mira 2 de sus 4 cartas y las memoriza. No se vuelven a
   ver.
3. **Turno:** robar del mazo o del descarte → cambiar por una carta de la mano
   (la vieja va al descarte) o descartar la robada directamente.
4. **Quemar:** en cualquier momento, cualquiera puede descartar una carta con el
   mismo número que la de arriba del descarte. Si falla, se lleva una carta de
   castigo. Hay una ventana de 4 s tras cada descarte en la que **nadie puede
   robar**, para que todos tengan tiempo de reaccionar.
5. **Carta quemada:** tras una quemada correcta, el descarte queda marcado
   (`discard_burned`) y **ya no se puede robar**, pero sí se puede seguir
   quemando encima. Se desbloquea cuando alguien descarta de forma normal.
6. **El 10:** al descartarlo, mira una carta de tu propia mano.
7. **El 11:** intercambio a ciegas en tres pasos —
   (a) quien lo juega elige rival,
   (b) quien lo juega se queda **a ciegas** una carta del rival,
   (c) **el rival** se queda **a ciegas** una carta suya.
   Nadie elige qué carta propia entrega. Ver `eleven_actor()` para saber a quién
   le toca decidir en cada momento.
8. **El 12:** espadas y oros valen 0 puntos; bastos y copas, 30. El resto vale
   su número.
9. **Dutch:** desde la ronda 4, al empezar tu turno. **Juegas ese turno con
   normalidad**, se da una última vuelta a los demás, y al volver a ti termina
   la partida.
10. **Fin por mano vacía:** quien se queda sin cartas gana en el acto.
11. **Fin por cartas agotadas:** si el mazo se vacía, se rebaraja el descarte
    (dejando la carta de arriba a la vista). Si tampoco se puede robar del
    descarte, la partida termina y se cuentan los puntos.

### Correcciones de reglas ya aplicadas

Estas tres se implementaron mal al principio y ya están corregidas. Anotadas
porque son fáciles de romper otra vez:

- Cantar Dutch **no** pasa el turno.
- En el 11, **nadie elige qué carta propia da**; el último paso lo resuelve el
  rival.
- Una carta quemada **no se puede robar** del descarte.

---

## 4bis. El tutorial guionizado

Está en `scenes/TutorialOverlay.gd` y son 30 pasos sobre una partida **de
verdad**, no una simulación. Se apoya en tres piezas:

| Pieza | Dónde | Qué hace |
|---|---|---|
| Reparto trucado | `GameLogic.start_scripted_game()` | Coloca manos y mazo tal cual, sin barajar |
| Rival a guion | `NetworkManager.tutorial_mode` | Siempre roba del mazo y tira lo robado; nunca quema, cambia ni canta Dutch |
| Rival congelado | `NetworkManager.tutorial_bots_paused` | El guion lo descongela sólo en los pasos en que toca verle jugar |
| Restricción de entrada | `Main.set_input_gate()` | Sólo responde el control que el paso autoriza (§3.7) |

**Por qué está trucado el reparto.** Porque permite pedir cosas concretas
—"cambia el 1 que acabas de robar por tu segunda carta, que es el 12 de
copas"— en vez de generalidades. Es la diferencia entre enseñar y describir.

**Las constantes `HANDS` y `DECK` son un mecanismo de relojería.** Cada carta
está donde está por una razón y el orden del mazo alterna aprendiz/rival:

```
0 espadas-1  yo   la cambio por el 12 de copas (suelto 30 puntos)
1 copas-3    Ana  la tira y yo quemo mi 3
2 espadas-10 yo   la descarto: efecto del 10
3 bastos-6   Ana  la tira (no tengo ningún 6: no puedo quemar)
4 bastos-11  yo   la descarto: efecto del 11
5 oros-7     Ana  la tira
6 espadas-12 yo   el 12 que vale 0: me lo quedo
7 bastos-4   Ana  su última vuelta tras mi Dutch
```

Si tocas una carta, **repasa el guion entero**. Con dos jugadores los turnos se
alternan, y eso hace que al llegar mi séptimo turno la ronda sea exactamente la
4: la mínima para poder cantar Dutch, sin tener que falsear la regla.

Las **tres cartas especiales** se juegan de verdad, no se explican: el 10
(mirar una carta propia), el 11 (intercambio a ciegas, con el rival eligiendo a
ciegas del lado del aprendiz) y el 12 (0 puntos en espadas y oros, 30 en copas
y bastos, enseñado dos veces: soltando el malo y quedándose el bueno).

El intercambio del 11 sería la única fuente de azar, así que el hueco que se
lleva el rival es fijo (`NetworkManager.TUTORIAL_BLIND_SLOT`). Gracias a eso el
marcador final es **siempre 6 contra 16**: el aprendiz gana su primera partida.

---

## 4ter. El multijugador online

### Cómo está montado

El reparto de papeles es **el mismo se juegue solo o en red**: el anfitrión es
el único que toca `GameLogic`, y los demás sólo *piden* cosas y reciben el
estado ya resuelto. Por eso `NetworkManager.request_*()` son funciones normales:
si eres el anfitrión se aplican ahí mismo, y si no, se mandan por la red. La
interfaz llama igual en los dos casos y no sabe si hay red o no.

```
  invitado                 relé (Node)              anfitrión
  --------                 -----------              ---------
  request_draw_deck()  ──►  reenvía  ──►  _apply_request(id, "draw_deck")
                                              │
                                        GameLogic.draw_from_deck()
                                              │
       state  ◄──  reenvía a todos  ◄──  var_to_bytes(state)
```

### Por qué NO es WebRTC

El proyecto tenía escrito WebRTC con servidor de señalización. Se tiró, por dos
razones que no tenían arreglo:

1. **Las plantillas web de Godot no pueden cargar extensiones nativas**, y
   WebRTC necesita una (`webrtc-native`). O sea que por ahí, quien juegue desde
   el navegador —los amigos con iPhone— se quedaba fuera para siempre.
2. Habría hecho falta además un **servidor TURN** aparte para atravesar las
   redes móviles.

Un relé WebSocket va en web y en Android con lo que Godot trae de serie, no
necesita TURN, y en un juego por turnos la latencia da igual.

### Los datos van en BINARIO, no en JSON

`var_to_bytes` / `bytes_to_var`, nunca `JSON.stringify`. Con JSON los enteros
vuelven convertidos en decimales, y `state.players[turn_index]` falla al indexar
con un decimal. `bytes_to_var` se llama **sin** `allow_objects`: un paquete que
llega de fuera jamás debe poder construir objetos.

### "Estoy listo" en la sala de espera

Cada invitado avisa de que está (`ready_lobby`), y hasta que no lo hacen todos
el anfitrión **no puede repartir**. La comprobación vive en `GameLogic`
(`start_game` se niega si `lobby_pending_names()` no está vacía), no sólo en el
botón: un botón en gris no es una regla.

El anfitrión no marca nada — su "estoy listo" es pulsar *Iniciar partida*. Los
bots nacen listos, así que una partida contra bots arranca de inmediato.

Ojo, son **dos** cosas distintas y con nombres parecidos:

| Campo | Cuándo | Qué significa |
|---|---|---|
| `ready_lobby` | Sala de espera | Estoy sentado y preparado para que repartas |
| `ready_peek` | Tras mirar tus 2 cartas | Ya las he memorizado, que empiece el juego |

### Bots para no tener que ser cuatro

Un bot es un jugador normal de `state.players` con la marca `bot`. Lo mueve el
anfitrión, exactamente igual que en una partida local, y para el resto de la
mesa es indistinguible de un humano lento. En la sala de espera el anfitrión
tiene **Añadir bot** / **Quitar bot** hasta completar los cuatro huecos.

Sus identificadores empiezan en `NetworkManager.BOT_BASE_ID` (101) para no poder
chocar con los que reparte el relé (1, 2, 3...).

### Si alguien se cae a mitad de partida

No se le puede echar sin más: sus cartas cuentan para el recuento y la ronda se
quedaría esperándole eternamente. Lo que se hace es **convertirlo en bot**
(`GameLogic.make_bot`), que termina de jugar su mano. Con móviles esto no es
raro: basta con que se bloquee la pantalla.

---

## 5. El arte, el audio y la interfaz

### 5.1 Nada de assets

**No hay ni un archivo de imagen ni de sonido en el proyecto** (salvo la música
y el icono). Todo se genera por código al arrancar:

- **`PixelArt.gd`** dibuja píxel a píxel las 40 cartas, el dorso, el hueco
  vacío, el fondo de mesa, el interior de la taberna, los 4 fotogramas de llama
  y la heráldica (castillo de Castilla, cruces patadas, filigranas). Todo se
  cachea en variables estáticas.
- **`Sfx.gd`** sintetiza los 14 efectos con modelos acústicos: cuerda pulsada
  (Karplus-Strong) para el laúd, parciales inarmónicos para los golpes de
  madera, ruido en paso alto para el papel, soplos con envolvente de campana
  para el fuego.

**Ventaja:** el proyecto pesa nada y se ve nítido a cualquier resolución.
**Coste:** generar todo tarda unas décimas de segundo al arrancar (los efectos
se sintetizan en diferido para no retrasar el primer fotograma).

### 5.2 La regla de oro del pixel art

> **Todos los tamaños de carta deben ser múltiplos enteros de 40×56.**

La carta base mide 40×56 px y se escala con filtro NEAREST. Los tamaños en uso
(`Main.gd`): `MINI_CARD` 40×56 (×1), `HAND_CARD`/`PILE_CARD`/`MODAL_CARD`
80×112 (×2), `SHOWCASE_CARD` 120×168 (×3). Si usas cualquier otro tamaño, los
píxeles salen de distinto grosor y se rompe el efecto.

El fondo se genera a 240×135 y se escala ×4 para dar exactamente 960×540.

### 5.3 Audio y volumen

- Un solo archivo de música: `music/A_Round_of_Dutch.mp3`. `Music.gd` escanea
  la carpeta, así que si añades más pistas basta con que el nombre contenga
  `menu` o `partida`/`game` para que cada pantalla use la suya.
- Hay **dos buses de audio** creados en tiempo de ejecución: `Music` y `Sfx`.
- El volumen del jugador se aplica **al bus, no al reproductor**. Es
  intencionado: los efectos del bus se procesan antes que su volumen, así que el
  analizador de espectro sigue recibiendo la señal completa y las llamas del
  menú siguen bailando aunque quites la música.
- El nivel se guarda en `user://settings.cfg`.
- Los efectos van a −11 dB, por debajo de la música.

### 5.4 Animación al ritmo de la música

`Music.gd` monta un `AudioEffectSpectrumAnalyzer` y expone:

- `Music.beat()` → 0..1, sube de golpe con cada pulso grave y decae.
- `Music.level()` → 0..1, energía continua de los graves.

Lo consumen `MenuFx.gd` (llamas, brasas, velo cálido) y `Main._process`
(cartas de portada y título). Si el analizador no estuviera disponible, cae a un
latido sintético de 120 ppm para que la escena no se quede quieta.

---

## 6. Trampas conocidas (leer antes de tocar código)

Estos siete fallos ya se cometieron y costaron tiempo encontrarlos. Están
comentados en el código, pero conviene tenerlos presentes.

### 6.1 `set_anchors_preset` no estira el nodo

`set_anchors_preset(PRESET_FULL_RECT)` **recalcula los desplazamientos para
conservar el rectángulo actual**. Si lo llamas *después* de `add_child`, cuando
el nodo aún mide 0×0, se queda de tamaño cero para siempre.

- Antes de `add_child` → funciona (los offsets valen 0).
- Después de `add_child` → **usa `set_anchors_and_offsets_preset`**.

Esto dejó el tutorial y la pantalla de reglas a 0×0, con el globo de texto
clavado en una esquina y el foco degenerado en una banda horizontal.

### 6.2 Arrays tipados contra el diccionario `state`

Los arrays dentro de `state` **no llevan tipo** (nacen como `[]` y por red
vuelven del JSON igual de pelados). Pasar uno de esos donde se espera
`Array[String]` **no es un aviso, es un error en tiempo de ejecución que aborta
la función a media faena**.

Esto impedía rebarajar el mazo: la línea del `slice` reventaba y la partida se
colgaba al agotarse la baraja. Usa `GameLogic._as_string_array()` para copiar.

### 6.3 `OVERRUN_TRIM_ELLIPSIS` hace desaparecer las etiquetas

Un `Label` con recorte por puntos suspensivos declara un ancho mínimo casi nulo,
y metido en una caja apretada el contenedor lo encoge hasta borrarlo. Así se
esfumaron los nombres de los rivales. `DutchUI.label()` va **sin recorte** por
defecto.

### 6.4 Las manos crecen: nunca uses filas de ancho fijo

Cada quemada fallida da una carta extra, y se han visto manos de 14 cartas. Una
`HBoxContainer` con cartas de ancho fijo se sale de la pantalla. Usa
**`CardFan`**, que las solapa tanto como haga falta. Ya está aplicado en la
mano, los asientos de los rivales, los tres modales y el marcador final.

### 6.5 Lambdas de varias líneas como argumento

Un lambda multilínea metido como argumento de una función deja el cierre del
paréntesis en un sitio ambiguo para el analizador. Si la condición tiene más de
una línea, **hazla un método con nombre**. En `TutorialOverlay` las condiciones
de los pasos van por otro camino: cada paso guarda el *nombre* de su condición y
`_step_done()` las resuelve todas en un `match`, que además deja el guion legible
de un vistazo.

### 6.6 Los navegadores no dejan sonar nada sin gesto previo

Si arrancas la música en el `_ready`, el navegador la descarta sin avisar y el
juego se queda mudo para siempre. `Music.gd` detecta `OS.has_feature("web")` y
espera al primer toque o tecla. En Android y escritorio no hay tal restricción.

### 6.7 Karplus-Strong necesita normalizar la púa

La amplitud de una cuerda pulsada depende del brillo del ruido inicial, no del
volumen que le pidas. Sin normalizar a fondo de escala, **la fanfarria de
victoria salía más floja que un clic de botón**. `Sfx._pluck()` normaliza.

---

## 7. Bloqueos actuales

### 7.1 El relé desplegado: dónde está y cómo se actualiza

- **Servicio:** `dutch-relay` en Render, plan gratuito, workspace de Vlad
  Cristian.
- **Dirección:** `wss://dutch-relay.onrender.com/` — es el valor por defecto en
  `NetworkManager.DEFAULT_RELAY_URL`, así que el jugador no configura nada.
- **Cómo cambiarla sin reexportar:** hay un **acceso oculto**, cinco toques
  seguidos en la línea pequeña de la portada ("Baraja española · 4 cartas...").
  No hay botón a la vista a propósito: a un jugador normal la palabra
  "servidor" sólo le desconcierta, y de cara a la Play Store da mala impresión.
  El código está en `Main._secret_zone()` / `Main._on_secret_input()`.
- **Comprobar que vive:** `curl https://dutch-relay.onrender.com/health`
- **Código:** `server/` del repositorio `github.com/xYRyLeYx/Dutch`.

**Se desplegó como "Public Git Repository", NO conectando la cuenta de GitHub**,
para no darle a Render acceso OAuth a todo el GitHub de Cristian. La
consecuencia práctica: **no hay despliegue automático al hacer push**. Si se
cambia `server/server.js`, hay que entrar en Render y pulsar *Manual Deploy*. Si
algún día molesta, se puede conectar la cuenta de GitHub y activarlo.

**Ojo con el `wss://`:** la versión web se sirve por `https`, y un navegador
bloquea las conexiones `ws://` sin cifrar desde una página segura. Por eso el
relé necesita TLS, que Render da hecho.

**El plan gratuito duerme** el servicio tras un rato sin uso y tarda ~30 s en
despertar. Si el primero que entra ve un fallo de conexión, que reintente.

### 7.2 iOS es imposible desde Windows

Apple exige macOS con Xcode para compilar y firmar, más una cuenta de
desarrollador (99 €/año) para repartir por TestFlight. No hay atajo.

**Alternativa que ya funciona:** la versión web se juega desde el navegador del
iPhone sin instalar nada — y ahora también online, porque el transporte se
cambió a WebSocket precisamente para no dejar fuera al navegador.

### 7.3 Lo que no está verificado

Sé honesto con esto al continuar:

- **El aspecto visual no se ha podido comprobar de forma automática.** No hay
  captura de pantalla disponible en el entorno donde se desarrolló. Todo el arte
  se validó replicando los algoritmos de dibujo en un canvas de navegador y
  mirando el resultado, no ejecutando Godot.
- **El APK no se ha ejecutado en un móvil real** desde el entorno de
  desarrollo. Cristian confirmó que funciona bien en su teléfono.
- **Los 14 efectos de sonido no se han escuchado.** Se validaron calculando sus
  formas de onda y midiendo pico, RMS y saturación (0 % en los 14).
- **El online sí se ha probado de verdad**, aunque en local: tres instancias
  del juego contra el relé en `localhost`, jugando partidas enteras y
  comprobando que todas terminan viendo el MISMO marcador. Se probaron 3
  humanos + 1 bot, 2 humanos + 2 bots, y una desconexión brusca a mitad de
  partida (el que se cae pasa a jugarlo un bot y la partida acaba bien). Lo que
  **no** se ha probado es entre dispositivos distintos ni desde el navegador.
  Sí se ha jugado una partida entera contra el relé **ya desplegado en Render**,
  por `wss://`, con los dos clientes coincidiendo en el marcador.
- El tutorial guionizado se verificó **en ejecución y sin pantalla**, no
  mirándolo: se recorrieron sus 30 pasos contra el motor de reglas real
  comprobando que cada condición llega a cumplirse, y se auditaron 356 controles
  (uno por paso y por control registrado) comprobando que en cada paso responde
  sólo lo que el guion marca y que lo señalado está en pantalla. El marcador
  final es determinista: 6 puntos contra 16. Lo que **no** se ha visto es su
  aspecto: el marco dorado, la flecha y la colocación del globo.

---

## 8. Cadena de compilación instalada

Todo en carpetas de usuario, **sin permisos de administrador y sin Android
Studio**.

| Componente | Ruta | Versión |
|---|---|---|
| Godot | `F:\Godot_v4.7.1-stable_win64.exe` | 4.7.1 stable |
| Plantillas de exportación | `%APPDATA%\Godot\export_templates\4.7.1.stable\` | 4.7.1 |
| JDK | `%LOCALAPPDATA%\Programs\jdk-17.0.20+8` | Microsoft OpenJDK 17.0.20 |
| SDK de Android | `%LOCALAPPDATA%\Android\Sdk` | build-tools 34.0.0, platform-tools, platform 34 |
| Keystore de depuración | `%APPDATA%\Godot\keystores\debug.keystore` | contraseña `android`, alias `androiddebugkey` |

Las rutas del JDK y del SDK están apuntadas en
`%APPDATA%\Godot\editor_settings-4.7.tres`.

### Presets de exportación (`export_presets.cfg`)

- **`Android`** → `build/dutch-0.1.0-alpha.apk`. Paquete `com.cristian.dutch`,
  arm64-v8a + armeabi-v7a, SDK mínimo 24 (Android 7.0), permisos de internet.
  Firmado con el keystore de depuración: **vale para repartir entre amigos, no
  para Google Play** (ahí haría falta un keystore propio y guardado a buen
  recaudo).
- **`Web`** → `build/web/index.html`. Exportado **sin hilos** a propósito: así
  no necesita las cabeceras COOP/COEP y funciona en cualquier hosting, incluido
  el Safari del iPhone.

### Publicar la versión web

itch.io → *Upload new project* → subir `dutch-web-0.1.0-alpha.zip` → marcar
**"This file will be played in the browser"** → *Embed options*: **960 × 540** y
activar *Fullscreen button*.

---

## 9. Próximos pasos

### Prioridad 1 — Desplegar el relé y probar entre móviles

Ya no hay nada que programar aquí, sólo administración. Pasos en
`server/README.md`; en resumen:

1. **Poner `server/` en internet** con TLS. Render es lo más rápido (plan
   gratuito, certificado incluido): repo de GitHub → New Web Service → Root
   Directory `server`, Build `npm install`, Start `npm start`.
2. **Escribir la dirección en el juego**: menú → **Servidor** → `wss://...`.
   Queda guardada en el dispositivo, así que esto **no obliga a reexportar**. La
   misma dirección en todos los aparatos que quieran jugar juntos.
3. **Probar entre dos móviles de verdad** y en redes distintas (uno por wifi y
   otro por datos). En local ya está probado, pero lo que no se ha visto todavía
   es cómo se comporta con la latencia y los cortes de una red móvil real.
4. **Probar el navegador contra el mismo relé**, que es el caso de los amigos
   con iPhone.

> El plan gratuito de Render duerme el servicio tras un rato sin uso, y
> despertarlo tarda medio minuto. Si el primero que entra ve un fallo de
> conexión, que reintente pasados unos segundos. Si molesta, cualquier VPS de
> pago lo evita.

### Prioridad 2 — Pulir la alpha con lo que digan los amigos

Cosas ya identificadas que convendría mirar:

- **Equilibrio de la penalización por fallar al quemar.** Con la regla actual,
  fallar sale muy caro: se han visto manos de 14 cartas, que vacían el mazo y
  hacen la partida rara. Opciones: limitar el tamaño de mano, o dar la carta de
  castigo sólo si queda mazo.
- **Dificultad de los bots.** `NetworkManager.BOT_BURN_CHANCE` está en 0.55
  (55 % de acordarse de quemar cuando pueden). Es el mando para hacerlos más
  fáciles o más duros.
- **Tipografía.** Ahora se usa una del sistema con el suavizado apagado. Si se
  deja un `.ttf` de píxeles en `res://assets/fonts/pixel.ttf`, el juego lo
  detecta solo y lo usa en todos los textos (ver `DutchUI._custom_pixel_font`).

### Prioridad 3 — Preparación para publicar

Sólo cuando el online funcione y la alpha esté probada:

- **Keystore de release propio**, guardado con copia de seguridad. Si se pierde,
  no se puede volver a actualizar la app en Play Store.
- **Subir `version/code`** en cada envío (ahora está en 1).
- **Iconos adaptativos** de Android (`launcher_icons/adaptive_*` en el preset
  están vacíos; ahora usa `icon.png` para todo).
- Revisar `targetSdkVersion` según lo que exija Play Store en ese momento.

### Ideas pendientes, sin prioridad

- Botón de reglas accesible **durante la partida** (ahora sólo desde el menú;
  `RulesScreen` ya se puede abrir desde cualquier pantalla, sólo falta el botón).
- Estadísticas: partidas jugadas, ganadas, puntuación media.
- Más pistas de música (el sistema ya las soporta por nombre de archivo).
- Vibración al quemar en móvil.

---

## 10. Consejos para quien siga

1. **La lógica va en `GameLogic.gd`, nunca en `Main.gd`.** Main es una función
   del estado; si le metes reglas, el online dejará de cuadrar.
2. **Si añades una acción que deba verse, emite un `_fx`.** Es lo que hace que
   todos los jugadores vean la misma animación.
3. **Prueba siempre con manos grandes.** Falla adrede varias quemadas y mira que
   nada se salga de la pantalla.
4. **Comprueba los tamaños de carta.** Múltiplos de 40×56, sin excepciones.
5. **`--headless` con `--quit-after` sirve para detectar errores de arranque**
   sin abrir ventana:
   ```bash
   "F:\Godot_v4.7.1-stable_win64.exe" --headless --path . --quit-after 240
   ```
   Y el propio export compila los scripts, así que si exporta sin errores es que
   todo analiza bien.
6. **Los avisos de "ObjectDB instances leaked at exit"** al usar `--quit-after`
   son del cierre forzado cortando los tweens, no un fallo real.
