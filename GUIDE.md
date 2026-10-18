# MatiBar — Guía de usuario

Tu Touch Bar custom, codeado desde cero. Barra a ancho completo (reemplaza el control strip de Apple).

## Layout normal
```
[ reloj ]  [ ───────── BATERÍA ───────── ]       [ 🔊 audio ] [ ✳ Claude ]
```
- **Reloj**: hora HH:MM, sin emoji.
- **Batería**: ocupa el centro, de la hora hasta los botones.
- **🔊 Audio**: toca para entrar al modo controles de reproducción.
- **✳ Claude**: abre tu ventana de Claude (logo sunburst, lugar de Siri).

## Batería — leyenda de colores

| Color | Qué significa |
|-------|---------------|
| 🟢 **Verde** + barrido hacia adelante | **Cargando** (enchufado y subiendo). El verde aparece al instante, sincronizado con el chime de carga. |
| ⚪ **Blanco** + barrido en reversa | **Descargando** (a batería). El barrido va hacia atrás = se vacía. |
| ⚪ **Blanco** estático | Enchufado pero **sin cargar** (ej: carga optimizada al 80%). |
| 🟡 **Amarillo** | **Modo ahorro de batería** (Low Power Mode) activado. |
| 🔴 **Rojo** | Batería **baja** (menos de 20%, a batería). |

El texto del `%` siempre se lee (blanco sobre la parte vacía, oscuro sobre la parte llena).

## El número de Watts (ej: `29.5W`)

- Es el **consumo EN VIVO (instantáneo)** — cuánta potencia se mueve en este instante.
- **No** es por hora, **no** es por segundo, **no** es carga restante. Watt ya es un ritmo (energía ÷ tiempo).
- **Descargando**: cuánto chupa el Mac ahora (sube jugando LoL ~20-40W, baja leyendo ~3-8W). Mientras más W, **más rápida** la animación.
- **Cargando**: cuántos W entran a la batería.
- El `%` = cuánto queda · el `W` = qué tan rápido se gasta/carga. Son cosas distintas y complementarias.

## Modo audio (tocar 🔊)
```
[ ‹ volver ]   ⏮  ⏯  ⏭   [ ♪ ──scrubber── ]   [ 🔊 ──volumen── ]
```
- **‹** vuelve a la barra normal.
- **⏮ ⏯ ⏭**: anterior / play-pausa / siguiente.
- **Scrubber (♪)**: posición de la canción — arrastrá para saltar a cualquier parte.
- **Volumen (🔊)**: volumen del sistema.
- Controla Spotify / Apple Music (lo que esté sonando).

## Modo día / clima (tocar el reloj)

Tocá **el reloj** y todo a su derecha se transforma en la vista del día; tocá de nuevo para volver.

- **Línea de tiempo del día completo** (00:00 → 23:59) con marcas cada hora.
- **Arco del sol** dibujado solo en la franja de luz (amanecer → atardecer), con el marcador de ahora: **sol** de día, **luna con su fase real** de noche.
- **Fondo animado** que hace match con la hora y el clima reales: día despejado, noche estrellada, nublado, lluvia, nieve, niebla, tormenta con rayos.
- **Íconos de lluvia** sobre las horas próximas con alta probabilidad.
- Temperatura, condición, fecha y máxima/mínima del día. Datos de Open-Meteo (gratis, ubicación por IP).

## Encender / apagar
- Encender (full-width): `./start.sh`
- Apagar y volver al Touch Bar normal de Apple: `./stop.sh`

## Notas
- Sin botón ✕: no se puede cerrar por accidente. Un watchdog la re-presenta sola si algo la tapa.
- El control de Spotify/Music necesita permiso de **Automation** — se pide bien cuando la app esté empaquetada y firmada.
