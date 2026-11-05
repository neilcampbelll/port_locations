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
    min_shore_km = if (all(is.na(distance_from_shore_m))) NA_real_ else
      min(distance_from_shore_m, na.rm = TRUE) / 1000,
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
  select(source, source_id, country, name, lon, lat, n_cells, n_at_dock, dist_ices_km, min_shore_km)

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
  select(source, source_id, country, name, lon, lat, min_shore_km) %>%
  st_as_sf(coords = c("lon", "lat"), crs = 4326, remove = FALSE) %>%
  st_transform(3035)

ports_cmp %>%
  st_drop_geometry() %>%
  count(source)


# GFW cells belonging to the ports kept in the ICES area
gfw_cells_ices <- gfw_cells %>%
  mutate(port_id = paste(country, name, cluster, sep = "_")) %>%
  filter(port_id %in% gfw_ices$source_id) %>%
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
    group_by(port_id) %>%
    slice_min(nn_dist_km, n = 1, with_ties = FALSE) %>%
    ungroup()
  
  m <- match(ports_cmp$source_id[is_gfw], best$port_id)
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

## Definitive port list

gfw_cover_km <- 1  # vmstools / UN points this close to a GFW cell are covered by the GFW footprint
dup_km       <- 3  # UN points this close to a vmstools point are treated as duplicates
max_offshore_km <- 5  # GFW ports whose nearest cell is further than this from shore are dropped

ports_final <- ports_cmp %>%
  filter(
    (source == "GFW" & (is.na(min_shore_km) | min_shore_km <= max_offshore_km)) |
      (source == "vmstools"  & gfw_dist_km > gfw_cover_km) |
      (source == "UN_LOCODE" & gfw_dist_km > gfw_cover_km & vms_dist_km > dup_km)
  ) %>%
  mutate(footprint = if_else(source == "GFW", "gfw_cells", "circle")) %>%
  select(source, source_id, country, name, lon, lat, footprint,
         un_name, un_dist_km, vms_name, vms_dist_km, gfw_name, gfw_dist_km)

## Apply reviewers' corrections (data/port_review.csv)

review_ports <- read_csv(
  "data/port_review.csv",
  col_types = cols(
    source_id = col_character(), action = col_character(), country = col_character(),
    name = col_character(), lon = col_double(), lat = col_double(),
    radius_km = col_double(), margin_m = col_double(), reason = col_character(),
    reviewer = col_character(), date = col_date(), issue = col_character()
  )
)

unknown <- review_ports %>%
  filter(action != "add", !source_id %in% ports_final$source_id)

if (nrow(unknown) > 0) {
  warning(nrow(unknown), " review row(s) name a source_id not in the port list: ",
          paste(unknown$source_id, collapse = ", "))
}

# Where a port has more than one move or resize, the last row wins
moves <- review_ports %>%
  filter(action == "move") %>%
  group_by(source_id) %>%
  slice_tail(n = 1) %>%
  ungroup()

resizes <- review_ports %>%
  filter(action == "resize") %>%
  group_by(source_id) %>%
  slice_tail(n = 1) %>%
  ungroup()

adds <- review_ports %>%
  filter(action == "add")

ports_final <- ports_final %>%
  st_drop_geometry() %>%
  filter(!source_id %in% review_ports$source_id[review_ports$action == "drop"]) %>%
  mutate(radius_km = NA_real_, margin_m = NA_real_) %>%
  rows_update(
    transmute(moves, source_id, lon, lat, footprint = "circle"),  # a moved port becomes a circle
    by = "source_id", unmatched = "ignore"
  ) %>%
  rows_update(
    select(resizes, source_id, radius_km, margin_m),
    by = "source_id", unmatched = "ignore"
  ) %>%
  bind_rows(
    transmute(adds,
              source    = "review",
              source_id = coalesce(source_id, paste0("REV_", country, "_", name)),
              country, name, lon, lat,
              footprint = "circle",
              radius_km)
  ) %>%
  st_as_sf(coords = c("lon", "lat"), crs = 4326, remove = FALSE)

review_ports %>%
  count(action)

# Before and after, by source
full_join(
  ports_cmp   %>% st_drop_geometry() %>% count(source, name = "compared"),
  ports_final %>% st_drop_geometry() %>% count(source, name = "final"),
  by = "source"
)

ports_final %>%
  st_drop_geometry() %>%
  write.csv("output/ports_final.csv", row.names = FALSE)

st_write(ports_final, "output/ports_final.gpkg", delete_dsn = TRUE)


src_col <- c(GFW = "steelblue", vmstools = "darkorange", UN_LOCODE = "firebrick", review = "darkgreen")
bb      <- st_bbox(ports_final)

plot(st_geometry(st_transform(land, 4326)), col = "grey90", border = "grey70",
     xlim = bb[c("xmin", "xmax")], ylim = bb[c("ymin", "ymax")])
plot(st_geometry(ports_final), pch = 20, cex = 0.3,
     col = src_col[ports_final$source], add = TRUE)
legend("topleft", legend = names(src_col), col = src_col, pch = 20, bty = "n")


## Port footprints: GFW cell polygons plus a margin, circles elsewhere

cell_margin_m <- 250  # added around each GFW port's cells
circle_km     <- 1    # radius for ports without GFW cells

gfw_keep <- ports_final$source_id[ports_final$footprint == "gfw_cells"]

# The GFW cells' source_id is their S2 cell token
gfw_cells_keep <- gfw_cells_ices %>%
  st_drop_geometry() %>%
  filter(port_id %in% gfw_keep)

cells <- s2::as_s2_cell(gfw_cells_keep$source_id)
stopifnot(all(s2::s2_cell_level(cells) == 14))  # check the tokens parsed as level-14 cells

gfw_poly <- gfw_cells_keep %>%
  mutate(geometry = st_as_sfc(s2::s2_cell_polygon(cells))) %>%
  st_as_sf() %>%
  st_transform(3035) %>%
  group_by(port_id) %>%
  summarise(.groups = "drop") %>%   # union of each port's cells
  rename(source_id = port_id) %>%
  left_join(st_drop_geometry(ports_final), by = "source_id")

# Default margin unless a reviewer has resized this port
gfw_poly <- st_buffer(gfw_poly, coalesce(gfw_poly$margin_m, cell_margin_m))

circles <- ports_final %>%
  filter(footprint == "circle") %>%
  st_transform(3035)

# Default radius unless a reviewer has set one
circles <- st_buffer(circles, coalesce(circles$radius_km, circle_km) * 1000)

footprints <- rbind(gfw_poly[, names(circles)], circles) %>%
  st_transform(4326)

footprints %>%
  st_drop_geometry() %>%
  count(footprint)

st_write(footprints, "output/port_footprints.gpkg", delete_dsn = TRUE)

## Clip footprints to the ICES areas and export as a shapefile

ices_union <- st_union(ices)

footprints_ices <- footprints %>%
  st_transform(3035) %>%
  st_intersection(ices_union) %>%
  st_collection_extract("POLYGON", warn = FALSE) %>%
  group_by(source, source_id) %>%
  summarise(across(c(country, name, lon, lat, footprint), first), .groups = "drop") %>%
  st_cast("MULTIPOLYGON") %>%
  st_transform(4326)

# Ports lost by the clip (entirely on land or outside the ICES areas)
full_join(
  footprints      %>% st_drop_geometry() %>% count(source, name = "before"),
  footprints_ices %>% st_drop_geometry() %>% count(source, name = "after"),
  by = "source"
)

footprints_ices %>%
  st_drop_geometry() %>%
  count(country, sort = TRUE)

st_write(footprints_ices, "output/port_footprints_ices.shp",
         layer_options = "ENCODING=UTF-8", delete_dsn = TRUE)
