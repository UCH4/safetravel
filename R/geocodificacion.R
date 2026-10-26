# ============================================================
# geocodificacion.R
# Normalización de direcciones para el origen y el destino.
# Acepta: dirección con altura ("Mercedes 1846 Llavallol"),
# cruce ("Mercedes y Ucrania", "Mercedes entre Ucrania y Hernandez"),
# coordenadas ("-34.6, -58.4") y links de Google Maps.
#
# Orden de resolución (todas las fuentes son gratuitas y sin clave):
#   1. Coordenadas o link de Google Maps (sin consultar servicios)
#   2. USIG (GCBA): normalizador oficial de CABA y AMBA
#   3. Georef (IGN / datos.gob.ar): normalizador oficial de Argentina
#   4. Nominatim (OpenStreetMap) como último recurso
# ============================================================

#' Pasa a minúsculas, sin acentos y con espacios simples.
normalizar_texto <- function(x) {
  x <- tolower(iconv(x, to = "ASCII//TRANSLIT", sub = ""))
  trimws(gsub("\\s+", " ", x))
}

#' Quita prefijos de tipo de vía ("Av.", "Avenida", "Calle") que los normalizadores no esperan.
#' "Av. Caseros y Av. Sáenz" -> "caseros y saenz".
limpiar_direccion <- function(texto) {
  t <- normalizar_texto(texto)
  t <- gsub("\\b(av|avda|avenida|calle|pje|pasaje)\\.?\\s+", "", t)
  trimws(gsub("\\s+", " ", t))
}

#' Caja de AMBA (con margen). Todo resultado fuera de esta caja se descarta.
AMBA_BBOX <- c(xmin = -58.85, ymin = -34.90, xmax = -58.20, ymax = -34.20)

#' TRUE si el punto cae dentro de AMBA.
dentro_amba <- function(lat, lon) {
  !is.na(lat) && !is.na(lon) &&
    lon >= AMBA_BBOX["xmin"] && lon <= AMBA_BBOX["xmax"] &&
    lat >= AMBA_BBOX["ymin"] && lat <= AMBA_BBOX["ymax"]
}

#' Reconoce "lat, lon" en texto (formato que se copia desde Google Maps).
coordenadas_desde_texto <- function(texto) {
  m <- regmatches(texto, regexec("^\\s*(-?\\d{1,2}\\.\\d+)\\s*[, ]\\s*(-?\\d{1,3}\\.\\d+)\\s*$", texto))[[1]]
  if (length(m) != 3) return(NULL)
  list(lat = as.numeric(m[2]), lon = as.numeric(m[3]), fuente = "coordenadas")
}

#' Extrae coordenadas o el nombre del lugar de un link de Google Maps.
#' Los links cortos (maps.app.goo.gl, goo.gl/maps) se resuelven siguiendo la redirección.
#' @return list(lat, lon, fuente) o list(texto = nombre del lugar) o NULL
desde_link_google_maps <- function(url) {
  url <- trimws(url)
  if (grepl("goo\\.gl|maps\\.app", url)) {
    r <- tryCatch(httr::GET(url, httr::timeout(8)), error = function(e) NULL)
    if (is.null(r)) return(NULL)
    url <- r$url
  }
  # !3d<lat>!4d<lon> es el punto del lugar; @lat,lon es solo el centro del mapa
  patrones <- c("!3d(-?\\d+\\.\\d+)!4d(-?\\d+\\.\\d+)",
                "@(-?\\d+\\.\\d+),(-?\\d+\\.\\d+)",
                "[?&](?:q|ll)=(-?\\d+\\.\\d+),(-?\\d+\\.\\d+)")
  for (p in patrones) {
    m <- regmatches(url, regexec(p, url, perl = TRUE))[[1]]
    if (length(m) == 3) {
      return(list(lat = as.numeric(m[2]), lon = as.numeric(m[3]), fuente = "Google Maps (link)"))
    }
  }
  nombre <- regmatches(url, regexec("/maps/place/([^/@]+)", url))[[1]]
  if (length(nombre) == 2) {
    texto <- utils::URLdecode(gsub("\\+", " ", nombre[2]))
    return(list(texto = texto))
  }
  NULL
}

#' Consulta el normalizador de USIG (GCBA). Devuelve una lista de candidatas.
consultar_usig <- function(texto) {
  r <- tryCatch(
    httr::GET("https://servicios.usig.buenosaires.gob.ar/normalizar/",
              query = list(direccion = texto, geocodificar = "true"),
              httr::timeout(10)),
    error = function(e) NULL
  )
  if (is.null(r) || httr::status_code(r) != 200) return(list())
  j <- jsonlite::fromJSON(httr::content(r, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  cand <- lapply(j$direccionesNormalizadas, function(x) {
    list(lat = as.numeric(x$coordenadas$y), lon = as.numeric(x$coordenadas$x),
         direccion = x$direccion, localidad = x$nombre_localidad,
         partido = x$nombre_partido, altura = x$altura, fuente = "USIG (GCBA)")
  })
  # Solo candidatas con coordenadas válidas dentro de AMBA
  Filter(function(c) dentro_amba(c$lat, c$lon), cand)
}

#' Consulta el normalizador de Georef (IGN) dentro de una provincia. Devuelve candidatas dentro de AMBA.
#' @param provincia nombre de provincia para acotar la búsqueda (por defecto CABA, luego Buenos Aires)
consultar_georef <- function(texto, provincia = "Ciudad Autónoma de Buenos Aires") {
  consulta <- list(direccion = texto, max = 5)
  if (!is.null(provincia)) consulta$provincia <- provincia
  r <- tryCatch(
    httr::GET("https://apis.datos.gob.ar/georef/api/direcciones", query = consulta, httr::timeout(10)),
    error = function(e) NULL
  )
  if (is.null(r) || httr::status_code(r) != 200) return(list())
  j <- jsonlite::fromJSON(httr::content(r, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  cand <- lapply(j$direcciones, function(x) {
    list(lat = x$ubicacion$lat, lon = x$ubicacion$lon,
         direccion = x$nomenclatura,
         localidad = x$localidad_censal$nombre,
         partido = x$departamento$nombre,
         altura = x$altura$valor, fuente = "Georef (IGN)")
  })
  Filter(function(c) dentro_amba(c$lat, c$lon), cand)
}

#' Separa una dirección "Calle 1846 entre X y Y" en la consulta a normalizar.
#' Con altura se usa "calle altura" (la altura manda). Sin altura, se usa el
#' cruce con la primera calle transversal, porque el normalizador resuelve intersecciones.
#' @return lista(consultas = vector de textos a probar, en orden)
generar_consultas <- function(texto) {
  t <- normalizar_texto(texto)
  t <- gsub("[.,;]", " ", t)
  t <- trimws(gsub("\\s+", " ", t))
  # "calle entre X y Y" / "calle esq X" / "calle y X"
  base <- sub("\\s+(entre|esq|esquina)\\s+.*$", "", t)
  cruce <- regmatches(t, regexec("\\s(?:entre|esq|esquina)\\s+(.+?)\\s+y\\s+(.+)$", t, perl = TRUE))[[1]]
  consultas <- character(0)
  if (length(cruce) == 3) {
    calle <- sub("\\s+\\d+.*$", "", base)
    tiene_altura <- grepl("\\d", base)
    if (tiene_altura) consultas <- c(consultas, base)
    consultas <- c(consultas, paste(calle, "y", cruce[2]))
  } else {
    consultas <- c(consultas, base)
  }
  unique(consultas)
}

#' Elige la mejor candidata. Si el usuario escribió una localidad o partido,
#' se prefiere la candidata que coincida con ese nombre.
elegir_candidata <- function(candidatas, pista_localidad = NULL) {
  if (length(candidatas) == 0) return(NULL)
  if (!is.null(pista_localidad)) {
    coincide <- vapply(candidatas, function(c) {
      grepl(pista_localidad, normalizar_texto(paste(c$localidad, c$partido)), fixed = TRUE)
    }, logical(1))
    if (any(coincide)) return(candidatas[[which(coincide)[1]]])
  }
  con_altura <- vapply(candidatas, function(c) !is.null(c$altura) && !is.na(c$altura), logical(1))
  if (any(con_altura)) return(candidatas[[which(con_altura)[1]]])
  candidatas[[1]]
}

#' Distancia aproximada en metros entre dos puntos (lat, lon).
distancia_m <- function(lat1, lon1, lat2, lon2) {
  r <- 6371000
  p1 <- lat1 * pi / 180; p2 <- lat2 * pi / 180
  dp <- (lat2 - lat1) * pi / 180; dl <- (lon2 - lon1) * pi / 180
  a <- sin(dp / 2)^2 + cos(p1) * cos(p2) * sin(dl / 2)^2
  2 * r * asin(sqrt(a))
}

#' Para "calle altura entre X y Y" devuelve la calle, la altura y los dos cruces.
#' @return NULL si no hay "entre"/"esq", o lista(base, calle, cruces)
extraer_entre <- function(texto) {
  t <- gsub("[.,;]", " ", normalizar_texto(texto))
  m <- regmatches(t, regexec("^(.+?)\\s+(?:entre|esq|esquina)\\s+(.+?)\\s+y\\s+(.+)$", t, perl = TRUE))[[1]]
  if (length(m) != 4) return(NULL)
  base <- trimws(m[2])
  list(base = base, calle = trimws(sub("\\s+\\d+.*$", "", base)),
       cruces = c(trimws(m[3]), trimws(m[4])))
}

#' Ubicación aproximada de una calle entre dos cruces (promedio de las intersecciones).
#' Sirve para elegir la calle correcta cuando hay homónimos (p. ej. Mercedes en CABA y en Llavallol).
punto_de_cruces <- function(entre) {
  pts <- lapply(entre$cruces, function(c) {
    cand <- consultar_usig(paste(entre$calle, "y", c))
    if (length(cand) == 0) return(NULL)
    cand[[1]]
  })
  pts <- Filter(Negate(is.null), pts)
  if (length(pts) == 0) return(NULL)
  list(lat = mean(vapply(pts, `[[`, numeric(1), "lat")),
       lon = mean(vapply(pts, `[[`, numeric(1), "lon")))
}

#' Normaliza una dirección con USIG, probando también sin palabras finales
#' (por ejemplo "Mercedes 1846 Llavallol" -> "Mercedes 1846", con pista "llavallol").
normalizar_con_usig <- function(texto) {
  # Caso "calle altura entre X y Y": elegir la altura más cercana a la intersección de los cruces
  entre <- extraer_entre(texto)
  if (!is.null(entre) && grepl("\\d", entre$base)) {
    ref <- punto_de_cruces(entre)
    cand <- consultar_usig(entre$base)
    con_altura <- Filter(function(c) !is.null(c$altura) && !is.na(c$altura), cand)
    if (length(con_altura) > 0) {
      if (!is.null(ref)) {
        d <- vapply(con_altura, function(c) distancia_m(ref$lat, ref$lon, c$lat, c$lon), numeric(1))
        elegida <- con_altura[[which.min(d)]]
      } else {
        elegida <- con_altura[[1]]
      }
      elegida$consulta <- entre$base
      return(elegida)
    }
  }

  palabras <- strsplit(normalizar_texto(texto), " ")[[1]]
  for (n_quitar in 0:min(2, length(palabras) - 2)) {
    n <- length(palabras) - n_quitar
    intento <- paste(palabras[seq_len(n)], collapse = " ")
    pista <- if (n_quitar > 0) paste(palabras[(n + 1):length(palabras)], collapse = " ") else NULL
    for (consulta in generar_consultas(intento)) {
      cand <- consultar_usig(consulta)
      elegida <- elegir_candidata(cand, pista)
      if (!is.null(elegida)) {
        elegida$consulta <- consulta
        return(elegida)
      }
    }
  }
  NULL
}

#' Geocodifica una dirección o punto escrito por el usuario.
#' @param direccion texto libre, coordenadas o link de Google Maps
#' @return lista con lat, lon, direccion, fuente (o NULL si no se pudo)
geocodificar_direccion <- function(direccion) {
  texto <- trimws(direccion)
  if (is.na(texto) || texto == "") return(NULL)

  # 1. Coordenadas directas
  pt <- coordenadas_desde_texto(texto)
  if (!is.null(pt)) return(c(pt, list(direccion = texto)))

  # 2. Link de Google Maps: coordenadas o nombre del lugar
  if (grepl("google\\.|goo\\.gl|maps\\.app", texto)) {
    gm <- desde_link_google_maps(texto)
    if (!is.null(gm$lat)) return(c(gm, list(direccion = texto)))
    if (!is.null(gm$texto)) texto <- gm$texto
  }

  # 3. Normalizadores oficiales (texto sin prefijos "Av.", "Calle")
  limpio <- limpiar_direccion(texto)
  usig <- normalizar_con_usig(limpio)
  if (!is.null(usig)) return(c(usig, list(direccion = usig$direccion)))

  # Georef acotado a CABA y luego a la provincia de Buenos Aires (AMBA).
  # Sin este sesgo, "Monteagudo 800" se resolvía en Chaco.
  for (prov in c("Ciudad Autónoma de Buenos Aires", "Buenos Aires")) {
    geo <- consultar_georef(limpio, provincia = prov)
    elegida <- elegir_candidata(geo, NULL)
    if (!is.null(elegida)) return(c(elegida, list(direccion = elegida$direccion)))
  }

  # 4. Último recurso: Nominatim (OpenStreetMap), acotado a CABA y descartando fuera de AMBA
  res <- tryCatch(
    tidygeocoder::geo(address = paste0(limpio, ", CABA, Argentina"), method = "osm", quiet = TRUE),
    error = function(e) NULL
  )
  if (is.null(res) || !dentro_amba(res$lat[1], res$long[1])) return(NULL)
  list(lat = res$lat[1], lon = res$long[1], direccion = paste0(limpio, ", CABA, Argentina"),
       fuente = "Nominatim (OSM)")
}
