# read data

library(readr)
library(dplyr)
library(sf)
library(countrycode)


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

