# Guía de la beta: Optimizador de rutas CABA (TP3, Grupo 3 – Comisión DF)

Prototipo en R + Shiny que compara la ruta más rápida con una alternativa que reduce la exposición a robos y hurtos históricos en CABA.

Estado: **beta usable** para probar la app con la grilla real. La simulación de 100 trayectos todavía no se rehizo con la grilla real (ver [TODO.md](TODO.md)).

---

## 1. Qué se usa y dónde (APIs y datos)

| Componente | Servicio | Dónde está configurado | Requisito |
|---|---|---|---|
| Ruteo | **OSRM** demo público: `https://router.project-osrm.org/` | `R/00_config.R` (línea 28) | Internet. Sin clave. Sin garantía de disponibilidad ni límite documentado; no usar para cientos de consultas seguidas. |
| Geocodificación | **Nominatim** (OpenStreetMap) vía `tidygeocoder` | `R/funciones_core.R` (`geocodificar_direccion`) | Internet. Sin clave. Política de uso: máximo ~1 consulta por segundo. |
| Ruteo alternativo (opcional) | Google Routes API | `MOTOR_RUTEO <- "google"` en `R/00_config.R` | Requiere `GOOGLE_MAPS_API_KEY` con facturación. **No se usa por defecto.** |
| Delitos | Datos abiertos CABA, *Delitos* (`data.buenosaires.gob.ar/dataset/delitos`) | `data/raw/delitos_YYYY.csv` | Descarga local (ver paso 2). |
| Barrios | Datos abiertos CABA, *Barrios* (GeoJSON) | `data/raw/barrios.geojson` | Descarga local (ver paso 2). |
| Población | Datos abiertos CABA, *Barrios* → Población por barrio (CSV) | `data/raw/poblacion_barrios.csv` | Descarga local. Todavía no se usa en el código. |

No hay backend propio ni base de datos: la app corre en tu máquina.

---

## 2. Requisitos

- R 4.3 o superior (probado con R 4.6.1).
- Conexión a internet (OSRM y Nominatim).
- Espacio: ~250 MB para los CSV de delitos.
- Los paquetes de R (`sf`, `osrm`, `tidygeocoder`, `leaflet`, `shiny`, `dplyr`, `purrr`, `ggplot2`) se instalan solos la primera vez, desde `R/00_config.R`.

---

## 3. Paso a paso

Todos los comandos se corren **desde la carpeta raíz del proyecto** (`TP3_Optimizador_Rutas/`).

### Paso 1: obtener el proyecto

Descomprimir el zip o clonar la carpeta. Verificar que existan `R/`, `data/` y `README.md`.

### Paso 2: descargar los datos (solo si no están en `data/raw/`)

Los 10 CSV anuales de delitos se bajan desde el portal. En 2019 y 2021 el portal redirige a un CDN, por eso se usan las URL directas:

```bash
mkdir -p data/raw
B="https://cdn.buenosaires.gob.ar/datosabiertos/datasets/ministerio-de-justicia-y-seguridad/delitos"
for y in 2016 2017 2018 2019 2020 2021 2022 2023 2024 2025; do
  curl -L -o data/raw/delitos_$y.csv "$B/delitos_$y.csv"
done
```

Después bajar `barrios.geojson` y `poblacion_barrios.csv` desde las fichas de datos:

- Barrios (GeoJSON): `https://data.buenosaires.gob.ar/dataset/barrios/resource/1c3d185b-fdc9-474b-b41b-9bd960a3806e/download`
- Población por barrio (CSV): `https://data.buenosaires.gob.ar/dataset/barrios/resource/5040e8fe-ce16-4d08-a091-b1dbe53335f1/download`

Guardarlos como `data/raw/barrios.geojson` y `data/raw/poblacion_barrios.csv`.

Verificación rápida: deben quedar 10 archivos `delitos_*.csv` (~350 MB en total).

### Paso 3: construir la grilla de riesgo

```bash
Rscript R/01_preparar_riesgo.R
```

Tarda varios minutos (1,4 millones de registros). Al terminar imprime:

```
Ajuste (2024): tamaño de celda = 500 m, peso nocturno = 1.0
Prueba 2025 (Spearman celdas, riesgo vs conteo real): 0.954
Grilla guardada en data/grilla_riesgo.rds (906 celdas).
```

Si imprime `[AVISO] Datos reales no disponibles`, revisar el paso 2: falta algún archivo, o el nombre no coincide.

### Paso 4: correr la app

```bash
Rscript -e 'shiny::runApp("R")'
```

Abre en `http://127.0.0.1:<puerto>` (el puerto lo muestra la consola). Es la única forma correcta: la app espera correr con el directorio de trabajo en `R/`, y `shiny::runApp("R")` lo hace.

Uso:
1. Escribir una dirección de origen (ej. `Plaza de Mayo 500`).
2. Escribir una dirección de destino (ej. `Av. Santa Fe 3253`).
3. Apretar **Calcular ruta óptima**.
4. El mapa muestra la ruta más rápida (azul), la ruta óptima (verde) y el mapa de calor de riesgo. El panel lateral muestra A, B, C y E.

Tiempo típico por consulta: unos segundos (depende de OSRM y Nominatim). La primera vez que arranca la app, además, geocodifica 6 direcciones de prueba para calcular C.

### Paso 5: correr la simulación de 100 trayectos

```bash
Rscript R/02_simulacion_resultados.R
```

Genera `data/resultados_simulacion.csv` y `data/comparacion_riesgo.png`, y deja en consola el resumen (reducción de riesgo, prueba estadística, A, B, C y E).

**Importante:** los resultados que hoy están en `data/resultados_simulacion.csv` se calcularon con la **grilla sintética** de la versión anterior. No usarlos en el informe; hay que volver a correr este paso con la grilla real. Tarda unos 10 a 15 minutos (300+ consultas a OSRM).

---

## 4. Motor Google (opcional)

Solo si se quiere probar Google Routes en la demo:

1. En `R/00_config.R`: `MOTOR_RUTEO <- "google"`.
2. En la consola de R: `Sys.setenv(GOOGLE_MAPS_API_KEY = "tu_clave")`. **No escribir la clave en ningún archivo del proyecto.**
3. Instalar: `install.packages(c("httr", "googlePolylines"))`.

No recomendado para la simulación: consume cuota.

---

## 5. Problemas conocidos

- **OSRM demo**: sin SLA. Si responde lento o con error, las consultas fallan y la app muestra el error en pantalla.
- **Nominatim**: direcciones muy informales pueden no geocodificarse. La app devuelve un error en pantalla; no reintenta.
- **Grilla gruesa**: con celdas de 500 m, la ruta óptima puede quedar dentro de la misma celda que la directa. Ver [TODO.md](TODO.md).
- **Aviso sintético**: si la grilla no se pudo construir, la app sigue funcionando con una grilla de demostración, pero solo lo indica en la consola (no en pantalla).
- **Arranque**: la primera carga de la app tarda por las consultas de C.

---

## 6. Estructura del proyecto

```
R/
  00_config.R              configuración (motor, pesos, parámetros, periodos)
  01_preparar_riesgo.R     construye la grilla de riesgo a partir de los CSV
  funciones_core.R         geocodificación, rutas candidatas, A, B, C
  app.R                    interfaz Shiny
  02_simulacion_resultados.R   100 trayectos + prueba estadística
data/
  raw/                     datos descargados (CSV, GeoJSON)
  grilla_riesgo.rds        grilla de riesgo construida (paso 3)
  resultados_simulacion.csv   salida del paso 5 (ver aviso)
  comparacion_riesgo.png
```
