// Relé de partidas de Dutch.
//
// Este servidor NO sabe nada del juego. Sólo agrupa a los jugadores en salas
// por código y reenvía paquetes entre ellos. Toda la lógica y las reglas siguen
// corriendo en el móvil del anfitrión, igual que en la partida local.
//
// Por qué un relé y no WebRTC (que es lo que había antes): las plantillas web
// de Godot no pueden cargar extensiones nativas, así que WebRTC dejaba fuera a
// quien juega desde el navegador — y además habría hecho falta un servidor TURN
// aparte para las redes móviles. Un relé va en web y en Android con lo que
// Godot trae de serie. Para un juego por turnos, la latencia da igual.
//
// Arrancar:   npm install && npm start
// Desplegar:  cualquier sitio que ejecute Node y dé una URL wss://
//             (Render, Railway, Fly.io, un VPS...). Ver README.md.

const http = require('http');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 8080;

// Tiene que coincidir con GameLogic.MAX_PLAYERS. El servidor lo comprueba
// igualmente: un cliente modificado no debería poder llenar una sala.
const MAX_PLAYERS = 4;

const ROOM_TTL_MS = 6 * 60 * 60 * 1000;   // salas abandonadas: se limpian solas

// Cuánto se da por "sigue con el juego abierto" a alguien que dejó de avisar.
// El juego avisa cada 10 s desde el menú, así que 40 s son cuatro avisos
// seguidos perdidos: da margen de sobra para una red lenta y, a la vez, no
// arrastra durante más de medio minuto a gente que ya ha cerrado el juego.
const PRESENCE_TTL_MS = 40000;
const MAX_ROOMS = 500;
const MAX_MESSAGE_BYTES = 256 * 1024;

/** code -> { code, peers: Map(id -> ws), nextId, createdAt, isPublic, playing } */
const rooms = new Map();

// Quién tiene el juego abierto sin estar en ninguna mesa. Los que SÍ están en
// una mesa ya se cuentan por su conexión, así que aquí sólo viven los del menú.
//
// La clave es un identificador anónimo que se inventa el propio juego: sirve
// para no contar dos veces al mismo aparato y no dice absolutamente nada de
// quién es. No se guarda en disco ni sale de la memoria del servidor.
/** id anónimo -> última señal (ms) */
const presence = new Map();

function enUnaMesa(id) {
  const buscado = String(id).slice(0, 40);
  for (const ws of wss.clients) {
    if (ws.clientId === buscado && ws.roomCode) return true;
  }
  return false;
}

function prunePresence() {
  const limite = Date.now() - PRESENCE_TTL_MS;
  for (const [id, visto] of presence) {
    if (visto < limite) presence.delete(id);
  }
}

// Sin vocales ni caracteres que se confundan al leerlos en voz alta (0/O, 1/I).
// Un código de sala se dicta por teléfono más veces de las que uno cree.
const CODE_ALPHABET = 'BCDFGHJKLMNPQRSTVWXYZ23456789';

function newRoomCode() {
  for (let intento = 0; intento < 50; intento++) {
    let c = '';
    for (let i = 0; i < 4; i++) c += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
    if (!rooms.has(c)) return c;
  }
  return null;
}

// Salas públicas abiertas: ni empezadas, ni llenas. Se ordenan por la más
// llena primero, para juntar a la gente en una mesa en vez de repartirla en
// varias medio vacías — con pocos jugadores, eso es la diferencia entre que
// haya partida o que no.
function openPublicRooms() {
  const out = [];
  for (const room of rooms.values()) {
    if (!room.isPublic || room.playing) continue;
    if (room.peers.size >= MAX_PLAYERS) continue;
    out.push(room);
  }
  out.sort((a, b) => b.peers.size - a.peers.size);
  return out;
}

// Un servidor HTTP de verdad y no sólo el WebSocket: casi todas las
// plataformas de despliegue comprueban que el puerto responde a una petición
// normal antes de dar por buena la instancia.
const server = http.createServer((req, res) => {
  // Access-Control-Allow-Origin hace falta para la versión WEB del juego: se
  // sirve desde otro dominio, y sin esta cabecera el navegador le bloquea la
  // consulta. Son datos públicos y anónimos (cuántos, no quiénes), así que
  // abrirlo a cualquier origen no expone nada.
  const json = (obj) => {
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'no-store',
    });
    res.end(JSON.stringify(obj));
  };

  const ruta = new URL(req.url, 'http://local');

  if (ruta.pathname === '/health') return json({ ok: true, rooms: rooms.size });

  // Cuánta gente hay ahora mismo, para que el juego pueda decirte si merece la
  // pena buscar partida o es mejor jugar contra bots. NO se manda ni un nombre:
  // sólo números.
  if (ruta.pathname === '/status') {
    // La propia consulta hace de "sigo aquí": el que pregunta cuánta gente hay
    // es, precisamente, alguien que tiene el juego abierto. Así no hace falta
    // una segunda petición sólo para anunciarse.
    const yo = ruta.searchParams.get('me');
    // ...salvo que ese mismo aparato esté YA sentado en una mesa: entonces su
    // conexión le cuenta y apuntarle otra vez aquí le contaría dos veces. Se
    // comprueba en el servidor y no se confía en que el cliente deje de
    // preguntar, porque una versión vieja o modificada del juego lo haría.
    if (yo && !enUnaMesa(yo)) presence.set(String(yo).slice(0, 40), Date.now());
    prunePresence();

    let esperando = 0;
    let jugando = 0;
    for (const room of rooms.values()) {
      if (room.playing) jugando += room.peers.size;
      else esperando += room.peers.size;
    }
    return json({
      conectados: wss.clients.size,
      // Todos los que tienen el juego abierto: los de las mesas más los que
      // andan por el menú. Nunca se solapan, porque al sentarse en una mesa se
      // borra su señal de menú.
      en_la_app: wss.clients.size + presence.size,
      en_el_menu: presence.size,
      esperando,          // gente sentada en mesas que aún no han repartido
      jugando,            // gente en partidas ya empezadas
      mesas_abiertas: openPublicRooms().length,
    });
  }

  res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('Relé de Dutch en marcha. Conecta por WebSocket a esta misma URL.\n');
});

const wss = new WebSocketServer({ server, maxPayload: MAX_MESSAGE_BYTES });

function sendJson(ws, obj) {
  if (ws && ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
}

function roomOf(ws) {
  return ws.roomCode ? rooms.get(ws.roomCode) : null;
}

function leaveRoom(ws) {
  const room = roomOf(ws);
  if (!room) return;
  room.peers.delete(ws.peerId);
  ws.roomCode = null;

  if (ws.peerId === 1) {
    // Se ha ido el anfitrión: la sala no puede seguir, porque es quien lleva
    // las reglas. Se avisa a todos y se cierra.
    for (const other of room.peers.values()) {
      sendJson(other, { t: 'host_left' });
    }
    rooms.delete(room.code);
    log(`sala ${room.code} cerrada (se fue el anfitrión)`);
    return;
  }
  for (const other of room.peers.values()) {
    sendJson(other, { t: 'peer_left', id: ws.peerId });
  }
  log(`sala ${room.code}: se fue el jugador ${ws.peerId} (${room.peers.size} dentro)`);
}

function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

wss.on('connection', (ws) => {
  ws.roomCode = null;
  ws.peerId = null;
  ws.clientId = null;
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (raw, isBinary) => {
    // ---- DATOS DEL JUEGO ----
    //
    // Trama binaria: [int32 LE destinatario][carga útil]. El servidor sólo
    // cambia la cabecera por el id de quien lo envía y lo reenvía tal cual; no
    // mira ni entiende la carga. Destinatario 0 = a todos los demás.
    //
    // Va en binario y no en JSON a propósito: la carga es el estado de la
    // partida serializado por Godot, y así los enteros siguen siendo enteros
    // al llegar. Pasarlo por JSON los convierte en decimales y rompe cosas
    // como state.players[turn_index].
    if (isBinary) {
      const room = roomOf(ws);
      if (!room || raw.length < 4) return;
      const target = raw.readInt32LE(0);
      const out = Buffer.from(raw);
      out.writeInt32LE(ws.peerId, 0);
      if (target === 0) {
        for (const [id, other] of room.peers) {
          if (id !== ws.peerId && other.readyState === other.OPEN) other.send(out);
        }
      } else {
        const dest = room.peers.get(target);
        if (dest && dest.readyState === dest.OPEN) dest.send(out);
      }
      return;
    }

    // ---- CONTROL ----
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch (e) {
      return;
    }
    const code = String(msg.room || '').toUpperCase().slice(0, 8);
    // En cuanto entra en una mesa, su conexión ya le cuenta: se le quita de la
    // lista del menú para no contarle dos veces, y se le apunta el
    // identificador a la conexión para no readmitirle después.
    if (msg.me) {
      ws.clientId = String(msg.me).slice(0, 40);
      presence.delete(ws.clientId);
    }

    switch (msg.t) {
      case 'host': {
        if (ws.roomCode) return;
        if (rooms.size >= MAX_ROOMS) {
          return sendJson(ws, { t: 'error', m: 'El servidor está lleno. Inténtalo en un rato.' });
        }
        // El código lo reparte el servidor, que es el único que sabe cuáles
        // están ocupados: así dos salas no pueden chocar.
        //
        // PERO se respeta el que mande el cliente si viene y está libre. Las
        // versiones anteriores del juego lo generaban ellas y luego lo enseñaban
        // por pantalla; si el servidor les devolviera otro distinto, sus amigos
        // escribirían un código que no existe. Esto mantiene vivas las copias ya
        // instaladas.
        const nuevo = (code && !rooms.has(code)) ? code : newRoomCode();
        if (!nuevo) return sendJson(ws, { t: 'error', m: 'El servidor está lleno. Inténtalo en un rato.' });
        const room = {
          code: nuevo,
          peers: new Map(),
          nextId: 2,
          createdAt: Date.now(),
          isPublic: !!msg.public,
          playing: false,
        };
        room.peers.set(1, ws);
        rooms.set(nuevo, room);
        ws.roomCode = nuevo;
        ws.peerId = 1;
        sendJson(ws, { t: 'hosted', room: nuevo, id: 1, public: room.isPublic });
        log(`sala ${nuevo} creada (${room.isPublic ? 'pública' : 'privada'})`);
        break;
      }

      // Buscar partida pública. El servidor no devuelve una lista para que el
      // jugador elija: devuelve UNA sala o ninguna. Con pocos jugadores, una
      // lista casi siempre estaría vacía y daría sensación de juego muerto; así
      // el cliente sabe que, si no hay nadie, le toca abrir mesa él.
      case 'quick': {
        if (ws.roomCode) return;
        const abiertas = openPublicRooms();
        const elegida = abiertas.length > 0 ? abiertas[0] : null;
        sendJson(ws, { t: 'match', room: elegida ? elegida.code : '' });
        break;
      }

      // El anfitrión avisa de que ya ha repartido, para que su sala deje de
      // ofrecerse a los que están buscando.
      case 'room': {
        const room = roomOf(ws);
        if (!room || ws.peerId !== 1) return;
        room.playing = !!msg.playing;
        break;
      }

      case 'join': {
        if (ws.roomCode) return;
        const room = rooms.get(code);
        if (!room) {
          return sendJson(ws, { t: 'error', m: 'No existe ninguna sala con ese código.' });
        }
        if (room.peers.size >= MAX_PLAYERS) {
          return sendJson(ws, { t: 'error', m: 'La sala está llena.' });
        }
        const id = room.nextId++;
        room.peers.set(id, ws);
        ws.roomCode = code;
        ws.peerId = id;
        const name = String(msg.name || '').slice(0, 20) || `Jugador ${id}`;
        sendJson(ws, { t: 'joined', room: code, id });
        sendJson(room.peers.get(1), { t: 'peer_join', id, name });
        log(`sala ${code}: entra ${name} como ${id} (${room.peers.size} dentro)`);
        break;
      }

      case 'bye':
        leaveRoom(ws);
        break;

      default:
        break;
    }
  });

  ws.on('close', () => leaveRoom(ws));
  ws.on('error', () => leaveRoom(ws));
});

// Los móviles se desconectan sin avisar en cuanto la pantalla se apaga o
// cambian de red, y esas conexiones muertas dejarían la sala ocupada para
// siempre. Un ping periódico las detecta y las echa.
const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) {
      ws.terminate();
      continue;
    }
    ws.isAlive = false;
    ws.ping();
  }
  prunePresence();
  const now = Date.now();
  for (const [code, room] of rooms) {
    if (now - room.createdAt > ROOM_TTL_MS) {
      for (const other of room.peers.values()) other.terminate();
      rooms.delete(code);
      log(`sala ${code} caducada`);
    }
  }
}, 30000);

wss.on('close', () => clearInterval(heartbeat));

server.listen(PORT, () => log(`relé de Dutch escuchando en el puerto ${PORT}`));
