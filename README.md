# Optimizador de rutas CABA: prevención de exposición delictiva

Prototipo web (R + Shiny + Leaflet) del TP3 de Metodología del Aprendizaje (ITBA, Grupo 3). Dado un origen y un destino en CABA, compara la ruta más rápida con una alternativa que reduce la exposición a robos y hurtos históricos.

Estado, problemas abiertos y próximos pasos: ver **[OBJETIVOS.md](OBJETIVOS.md)**.

## Qué hace

- **Mapa de riesgo:** grilla de 500 m sobre robos y hurtos de CABA 2016–2025 (sin 2020–2021).
- **Ruta óptima:** compara ruta directa y alternativas, y calcula A (eficacia), B (tiempo de respuesta), C (robustez de geocodificación) y E (eficiencia global).
- **Medios de transporte:** auto y a pie. El transporte público está en desarrollo.
- **Direcciones flexibles:** acepta "Mercedes 1846 Llavallol", "Mercedes y Ucrania", "Mercedes 1846 entre Ucrania y Hernandez", coordenadas, links de Google Maps, y clic en el mapa.

## Requisitos

- **R 4.4 o superior** (probado con 4.6.1).
- **Paquetes de R:** `shiny`, `leaflet`, `sf`, `osrm`, `tidygeocoder`, `httr`, `jsonlite`, `dplyr`, `ggplot2`, `DBI`, `RSQLite`, `data.table`. `00_config.R` instala los que falten.
- **Opcional, para ruteo a pie local:** Docker Desktop, con un servidor OSRM peatonal en el puerto 5001.
- **Opcional, para transporte público:** Java 21 y al menos 16 GB de RAM para OpenTripPlanner.

## Cómo correr la app

Desde la raíz del proyecto:

```bash
Rscript -e 'shiny::runApp("R")'
```

Luego abrir la dirección que muestra la consola (por ejemplo `http://127.0.0.1:4976`).

- **Auto:** usa el OSRM público. Necesita internet.
- **A pie:** usa el OSRM local si está levantado. Si no, usa Mapbox, que necesita `MAPBOX_TOKEN` en `~/.Renviron`.

### Ruteo a pie local (opcional)

El contenedor `osrm-peatonal` se creó a mano con el perfil `foot` sobre `data/osrm/argentina-latest.osrm`. Si ya existe, levantarlo con:

```bash
docker start osrm-peatonal
```

Si hay que recrearlo, el comando exacto no quedó documentado en el proyecto: verificar el perfil y los parámetros antes de reproducirlo. La forma general es un `osrm-routed` sobre los archivos `.osrm` procesados con el perfil `foot`, expuesto en el puerto 5000 del contenedor y en el 5001 del host.

### Credenciales

Las claves nunca van en el código ni en el repositorio. Se guardan en `~/.Renviron`:

```
MAPBOX_TOKEN=pk.xxxxxxxx
```

Reiniciar R después de editar ese archivo.

## Datos

Los datos pesados no están en el repositorio (ver `.gitignore`). La app necesita solo `data/grilla_riesgo.rds`, que sí está incluido.

### Para regenerar la grilla de riesgo

1. Descargar los CSV anuales de robos y hurtos de Buenos Aires Data (dataset "delitos") a `data/raw/delitos_2016.csv` … `delitos_2025.csv`, y el GeoJSON de barrios a `data/raw/barrios.geojson`.
2. Correr:

```bash
Rscript R/01_preparar_riesgo.R
```

Esto genera `data/grilla_riesgo.rds` con los parámetros de la grilla en un atributo.

### Para la base de transporte público (colectivos)

1. Colocar el GTFS de colectivos en `data/gtfs/colectivos-gtfs-2019-10-01.zip`. Es el GTFS de Buenos Aires Data reducido a los viajes del 1-oct-2019 (un día de servicio; el archivo completo de 209 MB supera la memoria al procesarlo).
2. Correr el ETL:

```bash
Rscript R/03_base_transporte.R
```

Genera `data/transporte.sqlite` con **tres tablas** y sus índices:

| Tabla | Contenido |
|---|---|
| `paradas_riesgo` | id_parada, nombre, lat, lng, score_riesgo (0–1, o NA fuera de la grilla) |
| `lineas_recorridos` | id_ruta, nombre_linea, ramal |
| `conectividad` | id_parada_origen, id_parada_destino, id_ruta, tiempo_estimado_entre_paradas, espera_manana_min, espera_tarde_min, espera_noche_min |

El ETL no lee `shapes.txt`. De `stop_times.txt` usa solo cinco columnas y elimina los segundos (los tiempos se pasan a minutos). Las esperas son el promedio por bloque horario: Mañana 06–12, Tarde 12–20 y Noche 20–06.

**Los horarios son del 1-oct-2019: están vencidos.** Ver OBJETIVOS.md, sección 4.2.

3. Evaluar el ruteo sesgado (opcional, tarda unos 5 minutos):

```bash
Rscript R/04_evaluacion_transporte.R
```

Genera `data/evaluacion_transporte.csv` y `data/evaluacion_transporte_resumen.txt`.

## Ruteo sesgado por riesgo en colectivos

`calcular_colectivo_seguro(origen, destino, franja, factor_sesgo, k_alternativas)`, en `R/transporte.R`, busca el recorrido en colectivo (con caminatas de acceso y egreso) con un algoritmo de camino mínimo (Dijkstra, paquete `igraph`).

Costo de cada tramo:

```
w = (tiempo_viaje + espera_franja / 2 [solo al subir]) * (1 + factor_sesgo * score_riesgo)
```

- `factor_sesgo = 0`: ruta más rápida.
- `factor_sesgo > 0`: se desvía de paradas y tramos de mayor riesgo, a costa de tiempo.
- Las alternativas se obtienen penalizando el recorrido anterior, para que sean distintas entre sí.

```r
source("R/00_config.R"); source("R/transporte.R")
rutas <- calcular_colectivo_seguro(list(lat = -34.6083, lon = -58.3712),
                                   list(lat = -34.5950, lon = -58.4002),
                                   franja = "Tarde", factor_sesgo = 1)
rutas[[1]]$tramos
```

La primera consulta construye el grafo (unos 20 segundos); las siguientes reutilizan el caché de la sesión.

### Supuestos del ruteo

- Caminata: 80 m/min. Acceso a paradas: hasta 500 m. Transbordo a pie: hasta 150 m entre paradas.
- Cada subida cuesta 3 min fijos, además de la espera de la franja.
- `score_riesgo` es el valor de la grilla de 500 m en la que cae la parada. Fuera de CABA no hay dato, así que cuenta como 0. **El sesgo solo actúa dentro de CABA.**
- Los horarios son programados del 1-oct-2019 (ver OBJETIVOS.md, sección 4.2).
- No hay modelo de capacidad, de tráfico ni de tiempo real.

## Planificador de transporte multimodal (OpenTripPlanner, en desarrollo)

OpenTripPlanner 2.6.0 necesita el grafo construido a partir de OpenStreetMap (`data/osrm/argentina-latest.osm.pbf`) y de los GTFS. Para construirlo:

1. Crear `data/otp/graph/build-config.json`:

```json
{
  "transitModelTimeZone": "America/Argentina/Buenos_Aires",
  "transitServiceStart": "2019-09-01",
  "transitServiceEnd": "2020-03-01"
}
```

2. Construir con 16 GB de heap:

```bash
cd data/otp && java -Xmx16g -jar otp-shaded-2.6.0.jar --build --save graph
```

Con el feed completo de colectivos, la construcción se queda sin memoria. Por eso se usa `colectivos-gtfs-2019-10-01.zip`, con los viajes de un solo día.

Todavía no está conectado a la app ni probado. Ver OBJETIVOS.md, sección 4.3.

## Estructura

| Archivo | Función |
|---|---|
| `R/00_config.R` | Parámetros: motor de ruteo, pesos de E, tamaño de celda, rutas de datos. |
| `R/01_preparar_riesgo.R` | Construye la grilla de riesgo a partir de los CSV. |
| `R/geocodificacion.R` | Normaliza direcciones: coordenadas, links de Google Maps, USIG, Georef, Nominatim. |
| `R/funciones_core.R` | Ruteo (OSRM, Mapbox, Google), rutas candidatas, cálculo de A, B, C y E. |
| `R/app.R` | Interfaz Shiny. |
| `R/02_simulacion_resultados.R` | Simulación de 100 trayectos y prueba estadística. Pendiente de volver a correr. |
| `R/03_base_transporte.R` | ETL del GTFS de colectivos: construye `data/transporte.sqlite` con tres tablas. |
| `R/04_evaluacion_transporte.R` | Verifica la base y compara ruta rápida vs. sesgada en 50 pares de puntos. |
| `R/transporte.R` | Grafo de colectivos, `calcular_colectivo_seguro()` y cliente de OpenTripPlanner. |
| `data/` | Datos derivados incluidos y datos pesados ignorados por git. |

## Documentos

- [OBJETIVOS.md](OBJETIVOS.md): objetivos, estado, errores abiertos y próximos pasos.
- [materiales_y_metodos.md](materiales_y_metodos.md): texto de métodos para el informe (desactualizado, ver OBJETIVOS.md).
- [GUIA_BETA.md](GUIA_BETA.md): guía de uso de la beta.
- [TODO.md](TODO.md) y [RELEVAMIENTO_ESTADO.md](RELEVAMIENTO_ESTADO.md): pendientes y comparación entre código y documento.
