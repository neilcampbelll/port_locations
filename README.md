# port_locations

A port footprint layer for the ICES VMS data call, used to remove vessel positions reported in port. It combines three port sources: the [vmstools](https://nielshintzen.github.io/vmstools) harbour list, UN LOCODE and [Global Fishing Watch](https://globalfishingwatch.org/datasets-and-code-anchorages/) named anchorages.

Where GFW has mapped a port's anchorage cells, the footprint follows those cells plus a 250 m margin. Elsewhere it is a 1 km circle. All footprints are clipped to the ICES areas.

- **Download the latest layer:** [port_footprints_ices.zip](https://github.com/neilcampbelll/port_locations/releases/latest/download/port_footprints_ices.zip) (shapefile, WGS 84)
- **Read how it was built:** [methods paper](https://neilcampbelll.github.io/port_locations/)

## Report a correction

If a port is missing, in the wrong place, not a port at all, or the wrong size, please [open a port correction issue](https://github.com/neilcampbelll/port_locations/issues/new/choose). The form asks for the port's `source_id`, which you can find in `ports_final.csv` on the [latest release](https://github.com/neilcampbelll/port_locations/releases/latest) or in the shapefile's attribute table.

Accepted corrections are recorded in `data/port_review.csv`, with the issue number, and the layer is rebuilt automatically.

## How the layer is rebuilt

Two GitHub Actions run on every push to `main`:

| Action | Runs when | What it does |
| --- | --- | --- |
| Build port footprints | `workflow.R` or anything in `data/` changes | Runs `workflow.R` and publishes the shapefile and `ports_final.csv` as the latest release |
| Publish methods paper | anything in `paper/` changes | Publishes `paper/index.md` as the methods paper site |

Both can also be started by hand from the Actions tab.

## Running it yourself

Open `port_locations.Rproj` in RStudio, or set the working directory to the top of the repo, and run `workflow.R`. Outputs are written to `output/`. The Natural Earth layers used to check UN LOCODE positions are downloaded to `data/natural_earth/` on the first run.

The script needs these R packages:

```r
install.packages(c("readr", "dplyr", "sf", "countrycode"))
remotes::install_github("nielshintzen/vmstools/vmstools/")  # for ICESareas
```

## Repository layout

| Path | Contents |
| --- | --- |
| `workflow.R` | The whole workflow, from reading the sources to exporting the shapefile |
| `data/` | The three port sources |
| `data/un_locode_review.csv` | Manual decisions on UN LOCODE positions: keep, drop or fix, with reasons |
| `data/port_review.csv` | Corrections from reviewers: drop, move, add or resize, with reasons |
| `paper/` | The methods paper |
| `.github/workflows/` | The two GitHub Actions |
| `.github/ISSUE_TEMPLATE/` | The port correction form |
