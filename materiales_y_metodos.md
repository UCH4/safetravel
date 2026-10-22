# Materiales y Métodos

> Texto listo para pegar en el `.docx` oficial (Grupo 3, Comisión DF). Redactado en pasado e impersonal, conforme a la guía de cátedra. Reemplaza/completa la sección que falta a continuación de la Introducción ya entregada.

## 1. Entorno de desarrollo y herramientas

El prototipo se desarrolló íntegramente en el lenguaje **R (versión 4.3 o superior)**, utilizando los siguientes paquetes del repositorio CRAN: `sf` (manejo de geometrías y sistemas de referencia espacial), `osrm` (consulta al motor de ruteo Open Source Routing Machine), `tidygeocoder` (geocodificación de direcciones), `leaflet` (visualización cartográfica interactiva), `shiny` (interfaz web del prototipo), `dplyr` y `purrr` (manipulación de datos) y `stats` (pruebas estadísticas de validación). La totalidad del código fuente se organizó en módulos independientes para su revisión y reproducción.

## 2. Fuentes de datos y preprocesamiento

Se utilizaron los registros oficiales de delitos (robos y hurtos) publicados por el Gobierno de la Ciudad Autónoma de Buenos Aires para el período 2016–2025, junto con las geometrías de los 48 barrios en formato GeoJSON, ambos disponibles en el portal de datos abiertos (data.buenosaires.gob.ar). Cada registro delictivo fue provisto originalmente en coordenadas geográficas (latitud/longitud, EPSG:4326, sistema WGS 84). Dado que esta proyección no preserva distancias de forma uniforme, las coordenadas se transformaron a un sistema de proyección plana en unidades métricas (POSGAR 2007 / UTM zona 21S, EPSG:5347), lo que permitió calcular distancias euclidianas y de proximidad de forma consistente.

Sobre las coordenadas proyectadas se construyó una **grilla de riesgo** de celdas cuadradas de 250 metros de lado, cubriendo la totalidad del polígono de la Ciudad. Para cada celda se calculó la cantidad de eventos delictivos históricos ocurridos en su interior, ponderada según la franja horaria y el día de la semana del trayecto consultado. El valor resultante se normalizó linealmente entre 0 y 1 respecto de la celda de mayor densidad observada, constituyendo el **índice de exposición delictiva** utilizado por el prototipo.

Se excluyó del entrenamiento de la grilla el período 2020–2021 por corresponder a la pandemia de COVID-19, no representativo de los patrones de movilidad y actividad delictiva habituales. Los registros 2016–2019 y 2022–2023 se utilizaron para construir la grilla de riesgo; los de 2024 para el ajuste del tamaño de celda y del factor de ponderación horaria; y los de 2025 se reservaron como conjunto de prueba, completamente excluido de las etapas anteriores, a fin de evaluar si la grilla conservaba capacidad explicativa fuera de la muestra utilizada para construirla.

## 3. Descripción del prototipo

Se diseñó un prototipo interactivo (aplicación web mediante el paquete `shiny`) que recibe como entrada una dirección de origen y una de destino en formato de uso habitual en Argentina (por ejemplo, "Plaza de Mayo 500, CABA"). El flujo de procesamiento consistió en las siguientes etapas, ejecutadas de forma secuencial:

1. **Geocodificación**: las direcciones de texto ingresadas se convirtieron a coordenadas geográficas mediante el servicio de geocodificación de OpenStreetMap (Nominatim), con la cadena ", CABA, Argentina" anexada automáticamente para reducir la ambigüedad propia de direcciones sin nomenclatura de calle única.
2. **Generación de rutas candidatas**: se solicitó al motor de ruteo OSRM (instancia pública de demostración, sin necesidad de clave de API) la ruta más rápida entre origen y destino. Sobre esa ruta base se generó un conjunto adicional de rutas candidatas insertando puntos de paso (*waypoints*) ubicados fuera de las celdas de mayor densidad delictiva atravesadas por la ruta directa, obligando al motor de ruteo a recalcular un trayecto alternativo que las evitara.
3. **Cálculo de exposición por ruta**: cada ruta candidata (representada como una polilínea georreferenciada) se intersectó contra la grilla de riesgo, acumulando el valor de exposición de cada celda atravesada, ponderado por la longitud del segmento de ruta dentro de esa celda.
4. **Selección de la ruta óptima**: se calcularon las variables normalizadas A, B y C (sección 4) para cada ruta candidata, y se seleccionó aquella que maximizó la Eficiencia global E definida en la Introducción.
5. **Visualización**: el resultado se representó sobre un mapa interactivo (`leaflet`), superponiendo la ruta directa, la ruta seleccionada como óptima y un mapa de calor de la grilla de riesgo en el área recorrida.

La arquitectura modular del prototipo permite reemplazar el motor de ruteo OSRM por la API de Google Routes (Google Maps Platform) sin modificar el resto del flujo, condicionado a la disponibilidad de una clave de API con facturación habilitada; esta alternativa se incorporó como configuración opcional del prototipo.

## 4. Distinción entre aspectos intrínsecos del diseño y variables de evaluación

Conforme a la guía de cátedra, no corresponde confundir las variables de evaluación del prototipo con los aspectos intrínsecos del problema que el diseño busca resolver. El tiempo de viaje de una ruta y su exposición al riesgo delictivo constituyen el objeto mismo del problema abordado —es decir, el resultado que el algoritmo produce— y se reportan como tales en la sección Resultados, pero no constituyen variables de evaluación del diseño tecnológico. Las variables de evaluación, en cambio, debieron caracterizar el comportamiento del prototipo como sistema de software frente al usuario: su eficacia al resolver la tarea para la que fue diseñado, su velocidad de respuesta y su robustez ante las condiciones reales de uso. En consecuencia, se definieron las variables A (Eficacia), B (Tiempo de respuesta) y C (Robustez de geocodificación), descriptas a continuación.

## 5. Determinación de la variable Eficacia (A)

La variable A cuantificó, para un par origen-destino dado, cuánto logró reducir el prototipo la exposición al riesgo de la ruta seleccionada respecto de la ruta más rápida (línea de base):

```
A = max(0, (riesgo_base − riesgo_óptima) / riesgo_base)
```

donde `riesgo_base` es la exposición acumulada de la ruta más rápida y `riesgo_óptima` es la exposición acumulada de la ruta finalmente seleccionada por el prototipo. Un valor A = 0 indicó que el prototipo no logró proponer ninguna mejora respecto de la ruta directa; valores cercanos a 1 indicaron una reducción casi total de la exposición acumulada. Se aplicó la función `max()` para acotar el valor inferior ante los casos en que la ruta seleccionada no mejoró la línea de base.

## 6. Determinación de la variable Tiempo de respuesta (B)

La variable B cuantificó la velocidad con la que el prototipo mostró un resultado al usuario, desde el envío de las direcciones de origen y destino hasta la renderización de la ruta en el mapa:

```
B = min(1, 5 / t_respuesta)
```

donde `t_respuesta` es el tiempo efectivo (en segundos) que demandó el ciclo completo de geocodificación, consulta de rutas candidatas y cálculo de exposición, y 5 segundos se adoptó como el tiempo de respuesta máximo aceptable para un uso interactivo del prototipo. Un tiempo de respuesta igual o menor a ese umbral produjo B = 1; tiempos mayores redujeron el valor de forma proporcional. Esta medición se repitió variando la resolución de la grilla de riesgo (celdas de 100, 250 y 500 metros) para caracterizar la relación entre granularidad espacial y costo computacional.

## 7. Determinación de la variable Robustez de geocodificación (C)

La variable C cuantificó la capacidad del prototipo para interpretar correctamente direcciones ingresadas en el formato informal de uso habitual en Argentina (sin aclaración de ciudad, con abreviaturas de uso corriente, o sin número de puerta), sin intervención manual del usuario:

```
C = direcciones_geocodificadas / direcciones_evaluadas
```

Para su determinación se construyó un conjunto de prueba de 50 direcciones reales de la Ciudad, escritas deliberadamente en formatos variados y parcialmente incompletos (por ejemplo, "Av. Cnel. Díaz 1700" en lugar de "Avenida Coronel Díaz 1700", o direcciones sin aclaración de barrio o ciudad). Se consideró una geocodificación exitosa cuando el punto devuelto por el servicio se ubicó dentro de un radio de 100 metros de la ubicación real verificada manualmente. El valor de C resultó, por construcción, acotado entre 0 y 1.

## 8. Determinación de la Eficiencia global (E)

La Eficiencia global del diseño se calculó como:

```
E = 0,5·A + 0,3·B + 0,2·C,  con 0 ≤ E ≤ 1
```

Las ponderaciones utilizadas priorizaron la eficacia del sistema para cumplir su propósito (α = 0,5) por sobre la velocidad de respuesta (β = 0,3) y la robustez de geocodificación (γ = 0,2), bajo el criterio de que un prototipo veloz y tolerante a direcciones mal escritas pierde valor si, en definitiva, no logra reducir la exposición al riesgo del usuario.

## 9. Diseño experimental de validación

Para evaluar el desempeño del prototipo se generó un conjunto de 100 pares de origen-destino, seleccionados aleatoriamente dentro del polígono de la Ciudad, ponderando la probabilidad de selección según la densidad poblacional de cada barrio para aproximar patrones de desplazamiento realistas. Para cada par se calcularon la ruta más rápida (línea de base) y la ruta óptima seleccionada por el prototipo, registrando el tiempo de viaje y el riesgo de exposición de cada una, junto con los valores resultantes de A, B, C y E. Sobre las 100 observaciones pareadas se aplicó una **prueba t de Student para muestras pareadas**, contrastando la hipótesis nula de que no existe diferencia significativa en la exposición al riesgo entre la ruta de base y la ruta óptima, contra la hipótesis alternativa de que la ruta óptima presenta una exposición significativamente menor. Se reportó adicionalmente el incremento porcentual promedio en el tiempo de viaje asociado a dicha reducción de riesgo, a fin de caracterizar —como resultado del problema resuelto, no como variable de evaluación del prototipo— el costo práctico de la mejora obtenida.
