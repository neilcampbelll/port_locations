# read data

library(readr)
library(dplyr)
library(sf)
library(countrycode)
library(vmstools)
data("ICESareas")

## Load and process the three files
# UN LOCODE 
un <- read_csv("data/UN_LOCODE ports.csv", show_col_types = FALSE) %>%
  transmute(
    source    = "UN_LOCODE",
    source_id = paste0(Country, Location),
    country   = Country,
    name      = Name,
    lon       = cent_lon,
    lat       = cent_lat
  )

# vmstools 
vms <- read_csv(
  "data/vmstools_harbours.csv",
  locale = locale(encoding = "latin1"),
  show_col_types = FALSE
) %>%
  transmute(
    source    = "vmstools",
    source_id = harbour,
    country   = NA_character_,
    name      = harbour,
    lon,
    lat,
    range
  )

# Global Fishing Watch
gfw <- read_csv(
  "data/named_anchorages_v2_pipe_v4_202609.csv",
  col_types = cols(
    s2id                  = col_character(),
    at_dock               = col_logical(),
    distance_from_shore_m = col_double(),
    drift_radius          = col_double()
  )
) %>%
  transmute(
    source    = "GFW",
    source_id = s2id,
    country   = countrycode(iso3, origin = "iso3c", destination = "iso2c"),
    name      = label,
    lon,
    lat,
    sublabel,
    label_source,
    at_dock,
    distance_from_shore_m,
    drift_radius
  )

# Combine 
ports_all <- bind_rows(un, vms, gfw) %>%
  st_as_sf(coords = c("lon", "lat"), crs = 4326, remove = FALSE)

ports_all %>%
  st_drop_geometry() %>%
  count(source)

dir.create("output", showWarnings = FALSE)
st_write(ports_all, "output/ports_all.gpkg", delete_dsn = TRUE)


## Clean the combined file...


max_sea_km    <- 5   # points in the sea further than this from the coast are flagged
max_inland_km <- 20  # points on land further than this from the coast are flagged

# get the Natural Earth 10m coastline
ne_dir <- "data/natural_earth"
dir.create(ne_dir, showWarnings = FALSE, recursive = TRUE)

for (layer in c("ne_10m_land", "ne_10m_coastline")) {
  zip_file <- file.path(ne_dir, paste0(layer, ".zip"))
  if (!file.exists(zip_file)) {
    download.file(
      paste0("https://naciscdn.org/naturalearth/10m/physical/", layer, ".zip"),
      zip_file,
      mode = "wb"
    )
    unzip(zip_file, exdir = ne_dir)
  }
}

# UN LOCODE points
un <- st_read("output/ports_all.gpkg", quiet = TRUE) %>%
  filter(source == "UN_LOCODE")

# Crop to the area around the points (planar), then project to ETRS89-LAEA to get meters.
s2_was_on <- sf_use_s2(FALSE)

bb <- st_bbox(un)
bb[c("xmin", "ymin")] <- bb[c("xmin", "ymin")] - 2
bb[c("xmax", "ymax")] <- bb[c("xmax", "ymax")] + 2

land <- st_read(file.path(ne_dir, "ne_10m_land.shp"), quiet = TRUE) %>%
  st_make_valid() %>%
  st_crop(bb) %>%
  st_transform(3035)

coast <- st_read(file.path(ne_dir, "ne_10m_coastline.shp"), quiet = TRUE) %>%
  st_crop(bb) %>%
  st_transform(3035)

sf_use_s2(s2_was_on)

un_3035 <- st_transform(un, 3035)

# checks 
un_checked <- un_3035 %>%
  mutate(
    on_land       = lengths(st_intersects(., land)) > 0,
    dist_coast_km = as.numeric(
      st_distance(., coast[st_nearest_feature(., coast), ], by_element = TRUE)
    ) / 1000,
    flag = case_when(
      !on_land & dist_coast_km > max_sea_km   ~ "at_sea",
      on_land  & dist_coast_km > max_inland_km ~ "inland",
      TRUE                                     ~ "ok"
    )
  ) %>%
  st_transform(4326)

un_checked %>%
  st_drop_geometry() %>%
  count(flag)

# Output 
un_checked %>%
  st_drop_geometry() %>%
  filter(flag != "ok") %>%
  select(source_id, country, name, lon, lat, on_land, dist_coast_km, flag) %>%
  arrange(flag, desc(dist_coast_km)) %>%
  write.csv("output/un_locode_flagged.csv", row.names = FALSE)

st_write(un_checked, "output/un_locode_checked.gpkg", delete_dsn = TRUE)




# manual review 
review <- read.csv("data/un_locode_review.csv", fileEncoding = "UTF-8")

unreviewed <- un_checked %>%
  st_drop_geometry() %>%
  filter(flag != "ok", !source_id %in% review$source_id)

if (nrow(unreviewed) > 0) {
  warning(nrow(unreviewed), " flagged point(s) not in the review file: ",
          paste(unreviewed$source_id, collapse = ", "))
}

un_clean <- un_checked %>%
  st_drop_geometry() %>%
  left_join(select(review, source_id, action, lon_new, lat_new), by = "source_id") %>%
  filter(!action %in% "drop") %>%
  mutate(
    lon = if_else(action %in% "fix", lon_new, lon),
    lat = if_else(action %in% "fix", lat_new, lat)
  ) %>%
  select(-lon_new, -lat_new) %>%
  st_as_sf(coords = c("lon", "lat"), crs = 4326, remove = FALSE)

un_clean %>%
  st_drop_geometry() %>%
  count(action)

st_write(un_clean, "output/un_locode_clean.gpkg", delete_dsn = TRUE)



## collapse GFW anchorage cells to ports and keep those in the ICES area

max_ices_km <- 20  
cluster_km  <- 5   

ices <- ICESareas %>%
  st_transform(3035) %>%
  st_make_valid()

# cut global file down
ices_bb <- st_bbox(st_transform(ICESareas, 4326))

gfw_cells <- st_read("output/ports_all.gpkg", quiet = TRUE) %>%
  filter(
    source == "GFW",
    between(lon, ices_bb["xmin"] - 2, ices_bb["xmax"] + 2),
    between(lat, ices_bb["ymin"] - 2, ices_bb["ymax"] + 2)
  ) %>%
  st_transform(3035)

xy <- st_coordinates(gfw_cells)

# within each name and country, link cells within cluster_km of each other
gfw_cells <- gfw_cells %>%
  st_drop_geometry() %>%
  mutate(x = xy[, "X"], y = xy[, "Y"]) %>%
  group_by(country, name) %>%
  mutate(
    cluster = if (n() == 1) 1L else
      cutree(hclust(dist(cbind(x, y)), method = "single"), h = cluster_km * 1000)
  ) %>%
  ungroup()

gfw_ports <- gfw_cells %>%
  group_by(country, name, cluster) %>%
  summarise(
    n_cells   = n(),
    n_at_dock = sum(at_dock, na.rm = TRUE),
    x         = mean(x),
    y         = mean(y),
    .groups   = "drop"
  ) %>%
  st_as_sf(coords = c("x", "y"), crs = 3035)

gfw_ports <- gfw_ports %>%
  mutate(
    dist_ices_km = as.numeric(
      st_distance(., ices[st_nearest_feature(., ices), ], by_element = TRUE)
    ) / 1000
  ) %>%
  st_transform(4326) %>%
  mutate(
    source    = "GFW",
    source_id = paste(country, name, cluster, sep = "_"),
    lon       = st_coordinates(.)[, "X"],
    lat       = st_coordinates(.)[, "Y"]
  ) %>%
  select(source, source_id, country, name, lon, lat, n_cells, n_at_dock, dist_ices_km)

gfw_ports %>%
  st_drop_geometry() %>%
  filter(dist_ices_km > max_ices_km, dist_ices_km <= 100) %>%
  arrange(dist_ices_km) %>%
  write.csv("output/gfw_near_edge.csv", row.names = FALSE)

gfw_ices <- gfw_ports %>%
  filter(dist_ices_km <= max_ices_km)

gfw_ices %>%
  st_drop_geometry() %>%
  count(country, sort = TRUE)

st_write(gfw_ices, "output/gfw_ports_ices.gpkg", delete_dsn = TRUE)


## Compare sources: nearest port in each other source

match_km <- 3  # ports in different sources within this distance are treated as the same port

dist_to_ices_km <- function(x) {
  x_3035 <- st_transform(x, 3035)
  as.numeric(
    st_distance(x_3035, ices[st_nearest_feature(x_3035, ices), ], by_element = TRUE)
  ) / 1000
}

# Apply the same ICES-area cut-off to vmstools and UN LOCODE as to GFW
vms_ices <- st_read("output/ports_all.gpkg", quiet = TRUE) %>%
  filter(source == "vmstools") %>%
  mutate(dist_ices_km = dist_to_ices_km(.)) %>%
  filter(dist_ices_km <= max_ices_km)

un_ices <- un_clean %>%
  mutate(dist_ices_km = dist_to_ices_km(.)) %>%
  filter(dist_ices_km <= max_ices_km)

# Common columns, rebuilt from lon/lat (the geometry column names differ between objects)
ports_cmp <- bind_rows(
  st_drop_geometry(un_ices),
  st_drop_geometry(vms_ices),
  st_drop_geometry(gfw_ices)
) %>%
  select(source, source_id, country, name, lon, lat) %>%
  st_as_sf(coords = c("lon", "lat"), crs = 4326, remove = FALSE) %>%
  st_transform(3035)

ports_cmp %>%
  st_drop_geometry() %>%
  count(source)

# GFW cells belonging to the ports kept in the ICES area
gfw_cells_ices <- gfw_cells %>%
  semi_join(st_drop_geometry(gfw_ices), by = c("country", "name", "cluster")) %>%
  mutate(source_id = paste(country, name, cluster, sep = "_")) %>%
  st_as_sf(coords = c("x", "y"), crs = 3035)

nearest <- function(x, y) {
  i <- st_nearest_feature(x, y)
  list(
    name    = y$name[i],
    dist_km = as.numeric(st_distance(x, y[i, ], by_element = TRUE)) / 1000
  )
}

for (col in c("un_name", "vms_name", "gfw_name"))          ports_cmp[[col]] <- NA_character_
for (col in c("un_dist_km", "vms_dist_km", "gfw_dist_km")) ports_cmp[[col]] <- NA_real_

is_un  <- ports_cmp$source == "UN_LOCODE"
is_vms <- ports_cmp$source == "vmstools"
is_gfw <- ports_cmp$source == "GFW"

# UN LOCODE <-> vmstools: point to point
nn <- nearest(ports_cmp[is_un, ], ports_cmp[is_vms, ])
ports_cmp$vms_name[is_un]    <- nn$name
ports_cmp$vms_dist_km[is_un] <- nn$dist_km

nn <- nearest(ports_cmp[is_vms, ], ports_cmp[is_un, ])
ports_cmp$un_name[is_vms]    <- nn$name
ports_cmp$un_dist_km[is_vms] <- nn$dist_km

# UN LOCODE and vmstools -> GFW: nearest GFW cell
nn <- nearest(ports_cmp[!is_gfw, ], gfw_cells_ices)
ports_cmp$gfw_name[!is_gfw]    <- nn$name
ports_cmp$gfw_dist_km[!is_gfw] <- nn$dist_km

# GFW -> UN LOCODE and vmstools: the closest any of the port's cells comes
for (s in c("un", "vms")) {
  target <- if (s == "un") is_un else is_vms
  nn     <- nearest(gfw_cells_ices, ports_cmp[target, ])
  
  best <- gfw_cells_ices %>%
    st_drop_geometry() %>%
    mutate(nn_name = nn$name, nn_dist_km = nn$dist_km) %>%
    group_by(source_id) %>%
    slice_min(nn_dist_km, n = 1, with_ties = FALSE) %>%
    ungroup()
  
  m <- match(ports_cmp$source_id[is_gfw], best$source_id)
  ports_cmp[[paste0(s, "_name")]][is_gfw]    <- best$nn_name[m]
  ports_cmp[[paste0(s, "_dist_km")]][is_gfw] <- best$nn_dist_km[m]
}

ports_cmp <- ports_cmp %>%
  mutate(
    n_matches = (coalesce(un_dist_km,  Inf) <= match_km) +
      (coalesce(vms_dist_km, Inf) <= match_km) +
      (coalesce(gfw_dist_km, Inf) <= match_km)
  ) %>%
  st_transform(4326)

# How many ports in each source are confirmed by 0, 1 or 2 other sources
ports_cmp %>%
  st_drop_geometry() %>%
  count(source, n_matches)

# By country, where unmatched ports are (vmstools has no country, so it's left out)
ports_cmp %>%
  st_drop_geometry() %>%
  filter(source != "vmstools") %>%
  group_by(country) %>%
  summarise(
    un            = sum(source == "UN_LOCODE"),
    un_unmatched  = sum(source == "UN_LOCODE" & n_matches == 0),
    gfw           = sum(source == "GFW"),
    gfw_unmatched = sum(source == "GFW" & n_matches == 0)
  ) %>%
  arrange(desc(gfw_unmatched))

# Output
ports_cmp %>%
  st_drop_geometry() %>%
  filter(n_matches == 0) %>%
  arrange(source, country, name) %>%
  write.csv("output/ports_unmatched.csv", row.names = FALSE)

st_write(ports_cmp, "output/ports_compared.gpkg", delete_dsn = TRUE)


