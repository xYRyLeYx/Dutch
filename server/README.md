# Relé de partidas de Dutch

Servidor diminuto que junta a los jugadores de una misma sala y les reenvía
paquetes. **No sabe nada del juego**: las reglas siguen corriendo en el móvil
del anfitrión, igual que en una partida contra bots. Si el relé se cae, lo único
que se pierde es la conexión, no la partida.

Son unas 180 líneas y una sola dependencia (`ws`). Aguanta de sobra a un grupo
de amigos: gasta unos pocos kilobytes por jugada.

---

## Probarlo en tu propio ordenador

```bash
cd server && npm install && npm start
```

Queda escuchando en `http://localhost:8080`. Para comprobar que vive:

```bash
curl http://localhost:8080/health
```

En el juego, botón **Servidor** del menú, y pon `ws://LA-IP-DE-TU-PC:8080/`
(la IP local, no `localhost`, si vas a conectarte desde el móvil). Con esto ya
se puede jugar entre dispositivos de tu casa, sin desplegar nada.

---

## Ponerlo en internet

Hace falta que la dirección final sea **`wss://`** (con TLS). No es un capricho:
la versión web del juego se sirve por `https`, y un navegador **bloquea** una
conexión `ws://` sin cifrar desde una página segura. Cualquiera de estos sitios
da el certificado hecho:

### Render (gratis, es lo más rápido)

1. Sube este proyecto a un repositorio de GitHub.
2. En [render.com](https://render.com) → **New** → **Web Service** → elige el repo.
3. Rellena:
   - **Root Directory:** `server`
   - **Build Command:** `npm install`
   - **Start Command:** `npm start`
4. Al desplegar te da una dirección `https://loquesea.onrender.com`.
   En el juego se pone **cambiando `https` por `wss`**:
   `wss://loquesea.onrender.com/`

> El plan gratuito de Render duerme el servicio tras un rato sin uso. La primera
> conexión después de dormir tarda medio minuto en despertar: si el primero que
> entra ve un fallo, que lo intente otra vez pasados unos segundos.

### Fly.io / Railway / un VPS

Vale el `Dockerfile` que hay aquí al lado tal cual. Lo único que hay que
respetar es que el proceso escuche en el puerto de la variable `PORT`, que ya lo
hace.

---

## Cómo se usa desde el juego

La dirección **no está compilada dentro de la aplicación**: se pone desde el
menú (botón **Servidor**) y queda guardada en el dispositivo. Así, si algún día
cambias de servidor, no hay que reinstalar nada.

Todos los que quieran jugar juntos tienen que tener **la misma dirección**.

---

## El protocolo, por si hay que depurarlo

Dos tipos de trama sobre el mismo WebSocket:

**Texto (JSON), sólo para entrar y salir:**

| Sentido | Mensaje |
|---|---|
| cliente → relé | `{"t":"host","room":"ABCD","name":"..."}` |
| cliente → relé | `{"t":"join","room":"ABCD","name":"..."}` |
| cliente → relé | `{"t":"bye"}` |
| relé → cliente | `{"t":"hosted","room":"ABCD","id":1}` |
| relé → cliente | `{"t":"joined","room":"ABCD","id":3}` |
| relé → anfitrión | `{"t":"peer_join","id":3,"name":"..."}` |
| relé → todos | `{"t":"peer_left","id":3}` / `{"t":"host_left"}` |
| relé → cliente | `{"t":"error","m":"..."}` |

**Binario, para el juego:** `[int32 LE destinatario][carga]`. El relé sólo
cambia esa cabecera por el identificador de quien lo envía y lo reenvía sin
mirar el contenido. Destinatario `0` = a todos los demás de la sala.

La carga va en binario y no en JSON a propósito: es el estado de la partida
serializado por Godot, y así los enteros siguen siendo enteros al llegar.
Pasándolo por JSON se convierten en decimales y cosas como
`state.players[turn_index]` fallan al indexar.

---

## Lo que el relé sí controla

- Códigos de sala repetidos (rechaza crear una que ya existe).
- Aforo: `MAX_PLAYERS` (4), por si alguien trastea con un cliente modificado.
- Salas abandonadas: se limpian solas a las 6 horas.
- Conexiones muertas: un ping cada 30 s las detecta y las echa. Hace falta de
  verdad, porque un móvil al que se le apaga la pantalla se va sin despedirse y
  si no dejaría la sala ocupada para siempre.

Lo que **no** controla es la partida. Un cliente modificado podría mandar
peticiones ilegales, pero es el anfitrión quien las valida contra las reglas, así
que lo peor que puede hacer es pedir cosas que le sean denegadas.
