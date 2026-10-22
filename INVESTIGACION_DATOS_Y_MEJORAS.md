# Investigación: fuentes de datos delictivos y mejoras al código

Fecha de la revisión: 2026-10-18.

## 1. Estado actual de los datos en el proyecto

- `data/` solo contiene **salidas de la simulación** (`resultados_simulacion.csv`, `comparacion_riesgo.png`).
- **No existe** `data/delitos_2016_2025.csv` ni `data/barrios.geojson`, que es lo que espera `R/01_preparar_riesgo.R` (líneas 19-20).
- Busqué en `~/Downloads`, `~/Documents`, `~/Desktop` y en iCloud Drive por `*delito*`, `*robo*`, `*crimen*`, `*hurto*`, `*barrios*.geojson`: no hay ningún archivo.
- `.Rhistory` está vacío. No hay rastro de que el dataset se haya cargado en este proyecto.

Por lo tanto, la grilla que usa la app y la simulación sigue siendo la **sintética**.

## 2. Fuente principal: Delitos de la Ciudad de Buenos Aires

Ficha verificada: <https://data.buenosaires.gob.ar/dataset/delitos> (Dirección General de Estadística Criminal y Mapa del Delito, Ministerio de Seguridad de CABA).

- Contenido: "homicidios, hurtos (sin violencia), lesiones y robos (con violencia)" ocurridos en CABA. **Incluye solo robos con violencia**, no todos los robos. Si el TP habla de "robos", hay que decidir si se filtra a `robos con violencia` o se toman también los hurtos.
- Formato: un recurso **por año**, en XLSX y CSV. En la página vi años 2016 a 2023. No pude confirmar 2024 y 2025 en el listado (el texto de la página se cortó).
- Campos: la descripción dice "fecha, hora y ubicación". **No pude ver los nombres de columnas**: el código asume `lat`, `lon`, `fecha`, `hora`, `tipo`, y eso hay que comprobarlo contra el CSV real antes de tocar nada.
- Hay que unir los CSV anuales en un solo archivo (`data/delitos_2016_2025.csv`) o cambiar el código para leer varios.
- Licencia: Creative Commons Attribution, según la ficha. Hay además una restricción de uso en la sección de información geográfica de la ciudad ("uso personal, no transferible"), que conviene revisar antes de publicar un derivado.
- Intenté leer la API CKAN (`/api/3/action/package_show`): la bloquea un WAF. Por eso el listado de recursos salió de la página HTML.
- El portal devolvió 502/504 en varios intentos y después respondió 200.

Mapa del Delito y estadística oficial (para validar): <https://mapa.seguridadciudad.gob.ar>. Contacto de metodología que figura en el informe: dgecmd@buenosaires.gob.ar.

## 3. Otras fuentes evaluadas

| Fuente | Nivel de detalle | Dirección / coordenadas | Utilidad para el TP |
|---|---|---|---|
| **CABA – Delitos** (datos.buenosaires.gob.ar) | Registro por hecho, anual | Sí (ubicación; a confirmar en columnas) | **Alta**. Es la fuente principal. |
| **CABA – Mapa del Delito** (mapa.seguridadciudad.gob.ar) | Agregado | Visual | Solo para validar resultados. |
| **SNIC – Estadísticas criminales** (datos.gob.ar) | Agregado nacional/provincial/departamental, desde 2014 (CSV) | No | Solo contexto, no sirve para la grilla. |
| **SNIC – SAT Homicidios dolosos** (datos.gob.ar) | Microdatos de homicidios | No confirmado | Baja: solo homicidios y sin confirmar dirección. |
| **PBA – catálogo gba** (catalogo.datos.gba.gob.ar) | Comisarías y unidades penitenciarias con lat/lon | Sí, pero son **ubicaciones de instituciones**, no delitos | Útil solo como capa de contexto. No encontré dataset de delitos georreferenciados de la provincia. |
| **Santa Fe – Criminalidad registrada** (santafe.gob.ar) | Informes agregados | No | No sirve para grilla. |
| **Córdoba** (mapa de investigación judicial) | Por circunscripción judicial | No | No sirve para grilla. |
| **Mendoza** (datos abiertos) | Sin dataset de delitos encontrado | — | No aplica. |
| **gba-delitos** (npm, comunitario) | Descarga del mapa provincial | No verificado | No oficial; no lo usaría para el informe. |

Conclusión: **para este TP la única fuente oficial, con dirección/coordenadas y de uso razonable, es el dataset de CABA**. Las demás son agregadas o solo sirven como contexto.

## 4. Problemas encontrados en el código

Ordenados por impacto en la validez del informe.

### 4.1 Prueba estadística inadecuada (alto)
`R/02_simulacion_resultados.R:83`: se usa `t.test` pareado sobre `riesgo_base` vs `riesgo_optimo`.

Con los 100 trayectos ya generados:
- Solo **6 de 100** trayectos cambiaron de ruta; en 94 la diferencia es exactamente 0.
- La diferencia tiene asimetría ≈ **6,9** (una cola con un trayecto de ~163 unidades).
- `t.test` da p ≈ 0,064; `wilcox.test` pareado (alternativa "greater") da **p ≈ 0,018**.

Con estos datos la conclusión cambia según la prueba. La t de Student no es confiable aquí. Recomendación: usar Wilcoxon pareado (con ties) y reportar también el efecto **solo sobre los trayectos que cambiaron de ruta**, más la proporción de cambios.

### 4.2 Normalización del riesgo (alto)
`R/01_preparar_riesgo.R:59` y `:92`: el riesgo se normaliza dividiendo por el máximo. Con densidades muy sesgadas, casi todas las celdas quedan en ~0 y la app pinta un mapa casi vacío. En la grilla sintética la mediana es ~1e-8.

Propuesta: usar cuantiles (percentil de la celda) o `log1p(conteo)` antes de normalizar, y documentar la elección en `materiales_y_metodos.md`.

### 4.3 Riesgo sin ponderar por tipo ni por tiempo (medio)
La grilla cuenta todos los delitos por igual (homicidios, lesiones, robos y hurtos). Conviene un peso por tipo y, si se quiere, un filtro temporal (p. ej. último año). Sin eso, un homicidio pesa lo mismo que un hurto.

### 4.4 Heurística de desvío mal documentada (medio)
`R/funciones_core.R:99`: el waypoint es el centroide de la celda riesgosa desplazado +0,0027° en lat y lon (~300 m). El comentario dice que el desvío va "en dirección opuesta a la concentración de riesgo" y que "se desplaza hacia la celda vecina de menor riesgo", pero el código **no hace eso**. El punto puede caer dentro de otra celda riesgosa.

Propuesta: elegir como waypoint el centro de una celda vecina de menor riesgo, a una distancia mayor que el lado de celda (250 m), y descartar los que caigan en celdas de riesgo alto. Corregir también el comentario.

### 4.5 Variable C con set de prueba placeholder (medio)
`R/02_simulacion_resultados.R:139-149`: solo 6 direcciones, con coordenadas de referencia tomadas a ojo. El `valor_c` de la app y del script (0,33) depende de esas 6 direcciones y de una tolerancia de 100 m, que es muy estricta para geocodificar números de calle con Nominatim. Antes del informe hay que armar un set de 50 direcciones con coordenadas verificadas y justificar la tolerancia.

### 4.6 Fallback silencioso a sintética (medio)
`R/01_preparar_riesgo.R:101-113`: si faltan los datos, solo se escribe un `message()` en consola. La app no le avisa al usuario que el mapa es ilustrativo. Propuesta: mostrar un aviso en la UI (`shiny::showNotification` o un banner) y guardar un atributo en la grilla que indique la fuente.

### 4.7 Lectura del CSV y detección de fechas (medio)
`R/01_preparar_riesgo.R:31-38`: `read.csv` sin control de tipos y `as.Date(fecha)` sin formato explícito. Con los CSV de CABA (archivos grandes, posible formato de fecha `dd/mm/yyyy`) eso puede fallar en silencio o dar `NA`. Propuesta: `readr::read_csv` con `col_types`, `lubridate::dmy`/`ymd` según el archivo, y un chequeo de cuántas filas quedan después de filtrar.

### 4.8 Carga de la app y arranque lento (bajo)
`app.R:25-29`: `VALOR_C_GLOBAL` hace llamadas a Nominatim al iniciar la app. Son ~6 requests de geocodificación en cada arranque. Propuesta: cachear el resultado en `data/` o calcularlo bajo demanda con un botón.

### 4.9 Paleta recalculada por polígono (bajo)
`app.R:91`: `colorNumeric("YlOrRd", riesgo)` se crea dentro de la fórmula, así que se recalcula para cada polígono de la grilla (~6.000). Propuesta: crear la paleta una sola vez fuera de la fórmula.

### 4.10 Código muerto y comentarios desactualizados (bajo)
- `R/02_simulacion_resultados.R:75`: `incProgress <- NULL` no hace nada.
- `R/funciones_core.R`: `googlePolylines` y `httr` se usan en la rama Google pero no están en `paquetes_requeridos` (`R/00_config.R`).
- `R/02_simulacion_resultados.R:135-138`: el comentario dice "set de prueba de 50 direcciones" y hay 6.

### 4.11 Ya corregido en esta sesión
- `source()` con rutas relativas (raíz vs `R/`).
- Bounding box de CABA con nombres duplicados (`xmin.xmin`), que daba `NA`.
- `osrmRoute(returnclass = ...)` no existe en osrm 6.0.0.
- Falta de `data/` antes de escribir la salida.

Verificado: la app arranca (HTTP 200), `calcular_ruta_optima()` funciona punta a punta con OSRM, y `02_simulacion_resultados.R` termina sin omisiones.

### 4.12 Lo que está bien (confirmado)
- El CRS proyectado `EPSG:5347` (POSGAR 2007 / UTM 21S) es el correcto para CABA, porque CABA (~58,4°W) cae en la zona 21.
- Los pesos de E suman 1 y hay un `stopifnot`.
- La separación entre A, B y C y lo que se reporta como resultado está bien explicada en el código.

## 5. Próximos pasos propuestos

1. **Confirmar con vos**: ¿tenés los CSV de CABA en otra máquina o carpeta? Si los tenés, pasame la ruta y los nombres de columnas. Si no, los descargo (son archivos grandes: te pido permiso antes de bajarlos).
2. Decidir el alcance del riesgo: ¿solo robos con violencia (lo que trae el dataset), o también hurtos?
3. Corregir la prueba estadística (4.1) y la normalización (4.2), que cambian resultados.
4. Adaptar `01_preparar_riesgo.R` a las columnas reales (4.7).
5. Armar el set de prueba de C con 50 direcciones verificadas (4.5).
6. Mejoras de UI y rendimiento (4.6, 4.8, 4.9).
