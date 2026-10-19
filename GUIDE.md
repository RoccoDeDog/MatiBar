# MatiBar — Guía de usuario

Tu Touch Bar custom, codeado desde cero. Barra a ancho completo (reemplaza el control strip de Apple).

## Layout normal
```
[ reloj ]  [ ───────── BATERÍA ───────── ]       [ 🔊 audio ] [ ✳ Claude ]
```
- **Reloj**: hora HH:MM. Tocalo para la vista del día y el clima.
- **Batería**: ocupa el centro, de la hora hasta los botones.
- **🔊 Audio**: tocalo para entrar a los controles de reproducción.
- **✳ Claude**: abre tu ventana de Claude.

Audio y Claude quedan siempre fijos a la derecha: los paneles cambian solo lo que está a su izquierda.

## Mantener apretado (1 segundo)

| Mantené… | Hace |
|----------|------|
| 🔊 **Parlante** | Silencia / quita el silencio del sistema (el ícono cambia). Cambiar el volumen quita el silencio. |
| **Carátula / canción** | Repite la canción actual (loop). Pasar de canción o que empiece otra lo apaga. |
| ⏯ **Play / pausa** | Abre / cierra el visualizador. |
| **Píxeles del visualizador** | Pasa al siguiente estilo. |
| ☀ **Sol** | **Blackout**: pantalla y teclado apagados; en la barra quedan solo ☀ 🔊 ✳. Tocá ☀ para volver. |
| **Reloj** | Abre Calendario. |
| **Vista del clima** | Abre la app Clima. |
| ✳ **Claude** | Abre un chat nuevo de Claude. |

Al dispararse, el botón destella un instante para confirmar.

## Batería — leyenda de colores

| Color | Qué significa |
|-------|---------------|
| 🟢 **Verde** + barrido hacia adelante | **Cargando**. El verde aparece al instante, sincronizado con el sonido de carga. |
| ⚪ **Blanco** + barrido en reversa | **Descargando** (a batería). El barrido va hacia atrás = se vacía. |
| ⚪ **Blanco** estático | Enchufado pero **sin cargar** (ej: tope de carga al 80%). |
| 🟡 **Amarillo** | **Modo ahorro de batería** (Low Power Mode) activado. |
| 🔴 **Rojo** | Batería **baja** (menos de 20%, a batería). |

El texto del `%` siempre se lee (blanco sobre la parte vacía, oscuro sobre la parte llena).

## El número de Watts (ej: `29.5W`)

- Es el **consumo EN VIVO (instantáneo)**: cuánta potencia se mueve en este instante.
- **No** es por hora ni carga restante. Watt ya es un ritmo (energía ÷ tiempo).
- **Descargando**: cuánto consume el Mac ahora (jugando sube a ~20-40W, leyendo baja a ~3-8W). Mientras más W, **más rápida** la animación.
- **Cargando**: cuántos W entran a la batería.
- El `%` = cuánto queda · el `W` = qué tan rápido se gasta o carga.

## Modo audio (tocar 🔊)
```
⏮  ⏯  ⏭   [ carátula · canción ]  [ ──scrubber── ]   🔉 [ volumen ] 🔊   ☀  🔊  ✳
```
- **⏮ ⏯ ⏭**: anterior / play-pausa / siguiente.
- **Carátula**: tocala para traer Spotify / Music al frente; mantenela para el **loop**.
- **Scrubber**: posición de la canción; arrastrá para saltar.
- **Volumen**: 10 barras del volumen del sistema; tocá, arrastrá o usá 🔉 / 🔊.
- **☀**: abre el brillo; mantenelo para el **blackout**.
- Controla Spotify / Apple Music (lo que esté sonando).

### Indicador de loop
Mientras la canción está en loop, la carátula y el título llevan un indicador. Hay 5 estilos:

| Estilo | Cómo se ve |
|--------|------------|
| 1 | Marco con flechas alrededor de la canción |
| 2 | Un punto orbitando con el recorrido tenue |
| 3 | Esquinas tipo visor + glifo de repetir |
| 4 | Insignia (siempre roja) |
| 5 | Dos puntos opuestos persiguiéndose, sin recorrido, + glifo de repetir |

```bash
defaults write com.mati.matibar loopStyle -int 5
defaults write com.mati.matibar loopColor red     # o white
```

## Modo brillo (tocar ☀ dentro de audio)
- **10 barras** de brillo de pantalla; tocá, arrastrá o usá los soles − / +.
- Hay un piso de seguridad: desde acá la pantalla nunca queda en negro por accidente.

## Blackout (mantener ☀)
- Pantalla al 0 %, luz del teclado apagada, y en la barra quedan solo ☀ 🔊 ✳. Ideal para escuchar música a oscuras.
- **Tocá ☀** para volver: el brillo y el teclado quedan como estaban (✳ también te saca, y abre Claude). En blackout, tocar 🔊 hace play/pausa.
- **Salvavidas**: antes de apagar, MatiBar guarda tu brillo en un archivo, y un **proceso guardián** aparte lo vigila. Si MatiBar se cae, la matan o se cuelga 12 segundos con la pantalla negra, el guardián te devuelve el brillo y el teclado (y si MatiBar murió, también la barra de Apple). Si el Mac se reinicia en pleno blackout, MatiBar lo restaura al arrancar.

## Modo día / clima (tocar el reloj)

Tocá **el reloj** y todo a su derecha se transforma en la vista del día; tocá de nuevo para volver. Mantené la vista para abrir la app Clima.

- **Línea de tiempo del día completo** (00:00 → 23:59) con marcas cada hora.
- **Arco del sol** sobre las horas de luz, con el marcador de ahora: **sol** de día, **luna con su fase real** de noche.
- **Trayectoria de la luna** de la noche, en línea punteada azul grisácea.
- **Fondo animado** según la hora y el clima reales: despejado, noche estrellada, nublado, lluvia, nieve, niebla, tormenta con rayos.
- **Íconos de lluvia** sobre las próximas horas con alta probabilidad.
- Temperatura, condición, fecha y máxima/mínima. Datos de Open-Meteo.
- **Ubicación precisa** si permitís Servicios de Localización (la primera vez macOS lo pregunta); si no, aproximada por IP.

## Visualizador (mantener ⏯ en modo audio)

Quedan ⏮ ⏯ ⏭ y todo lo demás se vuelve un campo de píxeles cuadrados sobre negro que reacciona a **todo lo que suena en el Mac** (Spotify, YouTube, juegos). Mantené ⏯ otra vez para salir. **Mantené los píxeles** para cambiar de estilo; el que elegís queda guardado.

| Estilo | Cómo se ve |
|--------|------------|
| **Horizontal** (por defecto) | Cada píxel es una frecuencia fija, leída como texto: graves abajo a la izquierda, agudos arriba a la derecha. Cuando su frecuencia golpea, se enciende al rojo blanco y se enfría en el lugar (blanco → rojo → azul). Halo de 50 % a los vecinos. |
| **Vertical** | El mismo mapa leído por columnas: graves a la izquierda, agudos a la derecha. Halo suave de 20 %. |
| **Espejo** | Espectro simétrico: graves rojos al centro, agudos azules a los bordes; crece en alto con el volumen y late con el bombo. |

- Horizontal y vertical son **balanceados**: cada píxel ve una tajada parecida del espectro (lineal hasta ~3,9 kHz, logarítmico arriba). Por eso una nota sostenida dibuja sus armónicos como un **peine** de dientes parejos.
- **Nada es al azar**: el mismo sonido dibuja siempre el mismo patrón, y en silencio queda todo negro.
- La primera vez macOS pide permiso de **Grabación de audio del sistema** (solo el audio del Mac, nunca el micrófono). Si lo negaste, el visualizador te avisa cómo activarlo.
- El audio se analiza en memoria y no se graba ni se guarda. La captura existe solo mientras el visualizador está abierto.
- Funciona aunque uses una salida virtual como Background Music.

```bash
defaults write com.mati.matibar visualizer horizontal   # o vertical, o espejo
```

## Encender / apagar
- Instalar (arranca solo al iniciar sesión): `./install.sh`
- Desinstalar y volver al Touch Bar normal de Apple: `./uninstall.sh`
- Para probar sin instalar: `./start.sh` y `./stop.sh`

## Notas
- Sin botón ✕: no se puede cerrar por accidente.
- El control de Spotify/Music necesita permiso de **Automatización**; macOS lo pide la primera vez.
- Los ajustes con `defaults write` se aplican al reiniciar MatiBar: `launchctl kickstart -k gui/$(id -u)/com.mati.matibar`.
