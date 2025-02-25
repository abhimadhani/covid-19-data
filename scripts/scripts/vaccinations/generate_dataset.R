library(data.table)
library(googlesheets4)
library(imputeTS)
library(lubridate)
library(readr)
library(retry)
library(rjson)
library(stringr)
library(tidyr)
library(jsonlite)
rm(list = ls())

setwd(dirname(rstudioapi::getSourceEditorContext()$path))
system("git pull")
CONFIG <- rjson::fromJSON(file = "vax_dataset_config.json")
Sys.setlocale("LC_TIME", "en_US")
gs4_auth(email = CONFIG$google_credentials_email)
GSHEET_KEY <- CONFIG$vax_time_series_gsheet

subnational_pop <- fread("../../input/owid/subnational_population_2020.csv", select = c("location", "population"))
continents <- fread("../../input/owid/continents.csv", select = c("Entity", "V4"))

AGGREGATES <- list(
    "World" = list("excluded_locs" = c("England", "Northern Ireland", "Scotland", "Wales"), "included_locs" = NULL),
    "European Union" = list("excluded_locs" = NULL, "included_locs" = fread("../../input/owid/eu_countries.csv")$Country)
)
for (continent in c("Asia", "Africa", "Europe", "North America", "Oceania", "South America")) {
    AGGREGATES[[continent]] = list(
        "excluded_locs" = NULL,
        "included_locs" = continents[V4 == continent, Entity]
    )
}

get_metadata <- function() {
    retry(
        expr = {metadata <- data.table(read_sheet(GSHEET_KEY, sheet = "LOCATIONS"))},
        when = "RESOURCE_EXHAUSTED",
        max_tries = 10,
        interval = 20
    )
    metadata <- metadata[include == TRUE]
    setorder(metadata, location)
    return(metadata)
}

add_aggregate <- function(vax, aggregate_name, included_locs, excluded_locs) {

    agg <- copy(vax)
    agg <- agg[!location %in% names(AGGREGATES)]
    if (!is.null(included_locs)) agg <- agg[location %in% included_locs]
    if (!is.null(excluded_locs)) agg <- agg[!location %in% excluded_locs]

    locations <- unique(agg[, "location"])
    locations[, id := 1]
    dates <- unique(agg[, "date"])
    dates[, id := 1]
    product <- merge(locations, dates, by = "id", allow.cartesian = TRUE)
    product[, id := NULL]

    agg <- merge(product, agg, by = c("date", "location"), all = TRUE)

    setorder(agg, location, date)

    for (loc in unique(agg$location)) {
        if (all(is.na(agg[location == loc, people_vaccinated]))) {
            agg[location == loc, people_vaccinated := 0]
        }
        if (all(is.na(agg[location == loc, people_fully_vaccinated]))) {
            agg[location == loc, people_fully_vaccinated := 0]
        }
    }

    agg[, total_vaccinations := na_locf(total_vaccinations, na_remaining = "keep"), location]
    agg[, people_vaccinated := na_locf(people_vaccinated, na_remaining = "keep"), location]
    agg[, people_fully_vaccinated := na_locf(people_fully_vaccinated, na_remaining = "keep"), location]

    agg <- agg[, .(
        total_vaccinations = sum(total_vaccinations, na.rm = TRUE),
        people_vaccinated = sum(people_vaccinated, na.rm = TRUE),
        people_fully_vaccinated = sum(people_fully_vaccinated, na.rm = TRUE)
    ), date]

    agg[, location := aggregate_name]
    agg <- agg[date < today()]
    vax <- rbindlist(list(vax, agg), use.names = TRUE)
    return(vax)
}

add_daily <- function(df) {
    setorder(df, date)
    df$new_vaccinations <- df$total_vaccinations - shift(df$total_vaccinations, 1)
    df[date != shift(date, 1) + 1, new_vaccinations := NA]
    return(df)
}

add_smoothed <- function(df) {
    setorder(df, date)
    original <- copy(df)
    complete_total_vax <- df[!is.na(total_vaccinations)]
    date_seq <- seq.Date(from = min(complete_total_vax$date), to = max(complete_total_vax$date), by = "day")
    time_series <- data.table(date = date_seq, location = df$location[1])
    if ("vaccine" %in% names(df)) time_series[, vaccine := df$vaccine[1]]
    df <- merge(df, time_series, all.y = TRUE, c("date", "location"))
    setorder(df, date)
    df[, total_interpolated := na_interpolation(total_vaccinations, option = "linear")]
    df[, new_interpolated := total_interpolated - shift(total_interpolated, 1)]
    windows <- head(c(0:6, rep(7, 1e4)), nrow(df))
    df[, new_vaccinations_smoothed := round(frollmean(new_interpolated, n = windows, adaptive = TRUE))]
    df[, c("total_interpolated", "new_interpolated") := NULL]
    original <- original[!date %in% df$date]
    df <- rbindlist(list(df, original), fill = TRUE)
    return(df)
}

process_location <- function(location_name) {
    message(location_name)
    is_automated <- metadata[location == location_name, automated]
    if (is_automated) {
        filepath <- sprintf("automations/output/%s.csv", location_name)
        df <- data.table(suppressMessages(read_csv(filepath)))
        stopifnot(all(names(df) %in% c("location", "source_url", "vaccine", "date", "total_vaccinations", "people_vaccinated", "people_fully_vaccinated")))
    } else {
        retry(
            expr = {df <- suppressMessages(read_sheet(GSHEET_KEY, sheet = location_name))},
            when = "RESOURCE_EXHAUSTED",
            max_tries = 10,
            interval = 20
        )
        setDT(df)
    }

    # Sanity checks
    stopifnot(length(unique(df$date)) == nrow(df))
    stopifnot(max(df$date) <= today())
    stopifnot(all(!is.na(df$location)))
    stopifnot(min(df$date) >= "2020-12-01")
    stopifnot(all(unlist(str_split(df$vaccine, ", ")) %in% c(
        "Pfizer/BioNTech", "Moderna", "Oxford/AstraZeneca", "Sputnik V", "Sinopharm/Beijing",
        "Sinopharm/Wuhan", "Johnson&Johnson", "Sinovac", "Covaxin", "EpiVacCorona"
    )))

    # Only report up to previous day to avoid partial reporting
    df <- df[date < today()]

    # Default columns for second doses
    if (!"people_vaccinated" %in% names(df)) df[, people_vaccinated := NA_integer_]
    if (!"people_fully_vaccinated" %in% names(df)) df[, people_fully_vaccinated := NA_integer_]

    # Check that vaccination logic is valid
    stopifnot(all(df$people_fully_vaccinated <= df$people_vaccinated, na.rm = TRUE))
    stopifnot(all(df$people_vaccinated <= df$total_vaccinations, na.rm = TRUE))

    df <- df[, c("location", "date", "vaccine", "source_url",
                 "total_vaccinations", "people_vaccinated", "people_fully_vaccinated")]

    df[, date := date(date)]

    setorder(df, date)
    fwrite(df, sprintf("../../../public/data/vaccinations/country_data/%s.csv", location_name), scipen = 999)
    return(df)
}

get_population <- function(subnational_pop) {
    pop <- fread("../../input/un/population_2020.csv", select = c("entity", "population"), col.names = c("location", "population"))
    pop <- rbindlist(list(pop, subnational_pop))

    # Add up population of US territories, which are reported as part of the US
    pop[location %in% c("American Samoa", "Micronesia (country)", "Guam", "Marshall Islands", "Northern Mariana Islands", "Puerto Rico", "Palau", "United States Virgin Islands"), location := "United States"]
    pop <- pop[, .(population = sum(population)), location]

    return(pop)
}

add_per_capita <- function(df, subnational_pop) {
    pop <- get_population(subnational_pop)
    df <- merge(df, pop)

    world_population <- pop[location == "World", population]
    covered <- unique(df[
        !location %in% names(AGGREGATES) & !location %in% subnational_pop$location,
        c("location", "population")
    ])
    COUNTRIES_COVERED <<- nrow(covered)
    WORLD_POP_COVERED <<- paste0(round(100 * sum(covered$population) / world_population), "%")

    df[, total_vaccinations_per_hundred := round(total_vaccinations * 100 / population, 2)]
    df[, people_vaccinated_per_hundred := round(people_vaccinated * 100 / population, 2)]
    df[, people_fully_vaccinated_per_hundred := round(people_fully_vaccinated * 100 / population, 2)]
    df[, new_vaccinations_smoothed_per_million := round(new_vaccinations_smoothed * 1000000 / population)]

    df[, population := NULL]
    return(df)
}

add_iso <- function(df) {
    iso_codes <- fread("../../input/iso/iso3166_1_alpha_3_codes.csv")
    df <- merge(iso_codes, df, by = "location", all.y = TRUE)
    return(df)
}

generate_automation_file <- function(metadata) {
    auto <- metadata[, c("location", "automated")]
    setorder(auto, -automated, location)
    fwrite(auto, "automations/automation_state.csv")
}

generate_locations_file <- function(metadata, vax) {
    setorder(vax, date)
    vax_per_loc <- vax[, .(vaccines = paste0(sort(unique(unlist(str_split(vaccine, ", ")))), collapse = ", ")), location]
    latest_meta <- vax[, .SD[.N], location]
    metadata <- merge(merge(metadata, vax_per_loc, "location"), latest_meta, "location")
    setnames(metadata, c("source_url", "date"), c("source_website", "last_observation_date"))
    metadata <- add_iso(metadata)
    metadata <- metadata[, c("location", "iso_code", "vaccines", "last_observation_date", "source_name", "source_website")]
    fwrite(metadata, "../../../public/data/vaccinations/locations.csv")
    return(metadata)
}

generate_vaccinations_file <- function(vax) {
    vax <- add_iso(vax)
    setnames(vax, c("new_vaccinations_smoothed", "new_vaccinations_smoothed_per_million", "new_vaccinations"),
             c("daily_vaccinations", "daily_vaccinations_per_million", "daily_vaccinations_raw"))
    fwrite(vax, "../../../public/data/vaccinations/vaccinations.csv", scipen = 999)
    generate_vaccination_json_file(copy(vax))
}

generate_grapher_file <- function(grapher) {
    setnames(grapher, c("date", "location"), c("Year", "Country"))
    setcolorder(grapher, c("Country", "Year"))
    grapher[, Year := as.integer(Year - ymd("2020-01-21"))]
    fwrite(grapher, "../../grapher/COVID-19 - Vaccinations.csv", scipen = 999)
}

generate_html <- function(metadata) {
    html <- copy(metadata)
    html[, location := paste0("<tr><td><strong>", location, "</strong></td>")]
    html[, last_observation_date := paste0("<td>", str_squish(format.Date(last_observation_date, "%b. %e, %Y")), "</td>")]
    html[, vaccines := paste0("<td>", vaccines, "</td></tr>")]
    html[, source := paste0('<td><a href="', source_website, '">', source_name, '</a></td>')]
    html <- html[, c("location", "source", "last_observation_date", "vaccines")]
    setnames(html, c("Location", "Source", "Last observation date", "Vaccines"))
    header <- paste0("<tr>", paste0("<th>", names(html), "</th>", collapse = ""), "</tr>")
    html[, body := paste0(Location, Source, `Last observation date`, Vaccines)]
    body <- paste0(html$body, collapse = "")
    html_table <- paste0("<table><tbody>", header, body, "</tbody></table>")
    coverage_info <- sprintf(
        "Vaccination against COVID-19 has now started in %s locations, covering %s of the world population.",
        COUNTRIES_COVERED,
        WORLD_POP_COVERED
    )
    message(coverage_info)
    html_table <- paste0("<p><strong>", coverage_info, "</strong></p>", html_table)
    writeLines(html_table, "automations/source_table.html")
}


generate_vaccination_json_file <- function(vax) {
    #' Generate JSON dataset
    vax_json <- jsonify_vax_data(vax)
    write(vax_json, "../../../public/data/vaccinations/vaccinations.json")
}

jsonify_vax_data <- function(vax) {
    #' Given data frame, jsonify it, i.e. suitable for API.
    #' More details, see https://github.com/owid/covid-19-data/issues/500
    countries <- get_list_countries_and_iso(vax)
    vax_json <- list()
    for (i in seq(nrow(countries))) {
        location <- countries[i, location]
        location_iso  <- countries[i, iso_code]
        vax_json[[i]] <- get_country_as_dix(
            vax, location = location, location_iso = location_iso
        )
    }
    # JSON format
    vax_json <- jsonlite::toJSON(vax_json, pretty = TRUE, auto_unbox = TRUE)
    return(vax_json)
}


get_list_countries_and_iso <- function(vax) {
    #' Get list of countries and iso codes (discard empty/NA codes)
    countries <- unique(vax[, c("location", "iso_code")])
    countries <- countries[!(is.na(countries$iso_code) | countries$iso_code %in% c(""))]
    return(countries)
}


get_country_as_dix <- function(vax, location, location_iso) {
    #' Get country data as a dictionary, API-friendly
    vax_country <- vax[iso_code == location_iso & location == location]
    country_data <- list(
        "country" = location,
        "iso_code" = location_iso
    )
    # Get data field (list, each element refers to one date)
    data <- vax_country[, -c("location", "iso_code")]
    setorder(data, date)
    country_data$data <- data
    return(country_data)
}


metadata <- get_metadata()
vax <- lapply(metadata$location, FUN = process_location)
vax <- rbindlist(vax, use.names = TRUE)

# Metadata
generate_automation_file(metadata)
metadata <- generate_locations_file(metadata, vax)

# Aggregate across all vaccines
vax <- vax[, .(
    total_vaccinations = sum(total_vaccinations),
    people_vaccinated = sum(people_vaccinated),
    people_fully_vaccinated = sum(people_fully_vaccinated)
), c("date", "location")]

# Add regional aggregates
for (agg_name in names(AGGREGATES)) {
    vax <- add_aggregate(
        vax, aggregate_name = agg_name,
        included_locs = AGGREGATES[[agg_name]][["included_locs"]],
        excluded_locs = AGGREGATES[[agg_name]][["excluded_locs"]]
    )
}

# Derived variables
vax <- rbindlist(lapply(split(vax, by = "location"), FUN = add_daily), fill = TRUE)
vax <- rbindlist(lapply(split(vax, by = "location"), FUN = add_smoothed), fill = TRUE)
vax <- add_per_capita(vax, subnational_pop)
vax[people_fully_vaccinated == 0, people_fully_vaccinated := NA]
vax[is.na(people_fully_vaccinated), people_fully_vaccinated_per_hundred := NA]

# Sanity checks
stopifnot(all(vax$total_vaccinations >= 0, na.rm = TRUE))
stopifnot(all(vax$new_vaccinations_smoothed >= 0, na.rm = TRUE))
stopifnot(all(vax$new_vaccinations_smoothed_per_million <= 120000, na.rm = TRUE))

setorder(vax, location, date)
generate_vaccinations_file(copy(vax))
generate_grapher_file(copy(vax))
generate_html(metadata)

source("generate_dataset_by_manufacturer.R")
