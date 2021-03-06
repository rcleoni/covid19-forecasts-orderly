## probs <- c(0.025, 0.25, 0.5, 0.75, 0.975)
probs <- c(0.01, 0.025, seq(0.05, 0.95, by = 0.05), 0.975, 0.99)
## weeks_ending <- readr::read_rds("latest_week_ending.rds")

output_files <- list.files(covid_19_path)
output_files <- output_files[grepl(x = output_files, pattern = week_ending)]

names(output_files) <- gsub(
  pattern = ".rds", replacement = "", x = output_files
)
names(week_ending) <- week_ending
message("For week ending ", week_ending)

message("Output Files ", output_files)

model_outputs <- purrr::map(
  output_files, ~ readRDS(paste0(covid_19_path, .))
)


## For each, for each country, pool projections from diff models
## In the output, the first level is week, 2nd is country and 3rd
## is SI.
ensemble_model_predictions <- purrr::map(
  week_ending,
  function(week) {
    idx <- grep(x = names(model_outputs), pattern = week)
    outputs <- purrr::map(model_outputs[idx], ~ .[["Predictions"]])
    ## First Level is model, 2nd is country, 3rd is SI.
    countries <- names(outputs[[1]])
    names(countries) <- countries
    purrr::map(
      countries,
      function(country) {
        message(country)
        message(names(outputs))
        ## y is country specific output
        y <- purrr::map(outputs, ~ .[[country]])
        ## y has 2 components, one for each SI.
        y_1 <- purrr::map(y, ~ .[[1]]) ## si_1
        y_2 <- purrr::map(y, ~ .[[2]]) ## si_1

        out <- list(
          si_1 = pool_predictions(y_1),
          si_2 = pool_predictions(y_2)
        )
      }
    )
  }
)

saveRDS(
  object = ensemble_model_predictions,
  file = "ensemble_model_predictions.rds"
)

## Model weights
weights <- readRDS(file = "unnormalised_model_weights.rds")
countries_grouped_by_models <- readRDS("countries_grouped_by_models.rds")


prev_week <- as.Date(week_ending) - 7
weights <- dplyr::filter(weights, forecast_date == prev_week)
models_this_week <- countries_grouped_by_models[[week_ending]]
models_prev_week <- countries_grouped_by_models[[as.character(prev_week)]]

normalised_wts <- split(weights, weights$si) %>%
  purrr::map(~ normalise_weights(., models_this_week, models_prev_week))

## Sanity check:  purrr::map(normalised_wts, ~ sum(unlist(.)))
if (nrow(weights) > 0) {
  wtd_ensemble_model_predictions <- purrr::map(
    week_ending,
    function(week) {
      idx <- grep(x = names(model_outputs), pattern = week)
      outputs <- purrr::map(model_outputs[idx], ~ .[["Predictions"]])
      models <- gsub(
        x = names(outputs),
        pattern = glue::glue("_Std_results_week_end_{week_ending}"),
        replacement = ""
      )
      ## First Level is model, 2nd is country, 3rd is SI.
      countries <- names(outputs[[1]])
      names(countries) <- countries
      purrr::map(
        countries,
        function(country) {
          message(country)
          message(names(outputs))
          ## y is country specific output
          y <- purrr::map(outputs, ~ .[[country]])
          ## y has 2 components, one for each SI.
          y_1 <- purrr::map(y, ~ .[[1]]) ## si_1
          y_2 <- purrr::map(y, ~ .[[2]]) ## si_1
          wts_1 <- normalised_wts[[1]][[country]][models]
          wts_2 <- normalised_wts[[2]][[country]][models]
          out <- list(
            si_1 = pool_predictions(y_1, wts_1),
            si_2 = pool_predictions(y_2, wts_2)
          )
        }
      )
    }
  )
} else {

  wtd_ensemble_model_predictions <- ensemble_model_predictions
}

saveRDS(
  object = wtd_ensemble_model_predictions,
  "weighted_ensemble_model_predictions.rds"
)


ensemble_model_rt <- purrr::map_dfr(
  week_ending,
  function(week) {
    message("Week is ", week)
    idx <- grep(x = names(model_outputs), pattern = week)
    message("Working on models ", names(model_outputs)[idx])
    outputs <- purrr::map(model_outputs[idx], ~ .[["R_last"]])
    ## First Level is model, 2nd is country, 3rd is SI.
    ## TODO pick countries from inout
    countries <- names(outputs[[2]])
    names(countries) <- countries
    purrr::map_dfr(
      countries,
      function(country) {
        if (week == "2020-04-12" & country == "United_Kingdom") {
          outputs <- outputs["sbsm_Std_results_week_end_2020-04-12"]
        }

        ## y is country specific output
        y <- purrr::map(outputs, ~ .[[country]])
        ## y has 2 components, one for each SI.
        ## Determine quantiles

        y_1 <- purrr::map(y, ~ .[[1]]) ## si_1
        ## smallest observation greater than or equal to lower hinge - 1.5 * IQR
        y_1_all <- unlist(y_1)
        y_1 <- quantile(
          y_1_all,
          probs = probs
        )
        y_1 <- tibble::rownames_to_column(
          data.frame(out2 = y_1),
          var = "quantile"
        )
        y_1$si <- "si_1"

        y_2 <- purrr::map(y, ~ .[[2]]) ## si_1
        y_2_all <- unlist(y_2)
        y_2 <- quantile(
          y_2_all,
          probs = probs
        )
        y_2 <- tibble::rownames_to_column(
          data.frame(out2 = y_2),
          var = "quantile"
        )
        y_2$si <- "si_2"
        rbind(y_1, y_2)
      },
      .id = "country"
    )
  },
  .id = "model" ## this is really week ending, but to be able to resue prev code, i am calling it model
)

ensemble_daily_qntls <- purrr::map_dfr(
  ensemble_model_predictions,
  function(pred) {
    purrr::map_dfr(
      pred, ~ extract_predictions_qntls(., probs),
      .id = "country"
    )
  },
  .id = "proj"
)

ensemble_weekly_qntls <- purrr::map_dfr(
  ensemble_model_predictions,
  function(pred) {
    purrr::map_dfr(
      pred,
      function(x) {
        message(colnames(x))
        daily_to_weekly(x)
      },
      .id = "country"
    )
  },
  .id = "proj"
)


wtd_ensemble_daily_qntls <- purrr::map_dfr(
  wtd_ensemble_model_predictions,
  function(pred) {
    purrr::map_dfr(
      pred, ~ extract_predictions_qntls(., probs),
      .id = "country"
    )
  },
  .id = "proj"
)

wtd_ensemble_weekly_qntls <- purrr::map_dfr(
  wtd_ensemble_model_predictions,
  function(pred) {
    purrr::map_dfr(
      pred,
      function(x) {
        message(colnames(x))
        daily_to_weekly(x)
      },
      .id = "country"
    )
  },
  .id = "proj"
)


saveRDS(
  object = ensemble_model_rt,
  file = "ensemble_model_rt.rds"
)

saveRDS(
  object = ensemble_daily_qntls,
  file = "ensemble_daily_qntls.rds"
)

saveRDS(
  object = ensemble_weekly_qntls,
  file = "ensemble_weekly_qntls.rds"
)

saveRDS(
  object = wtd_ensemble_daily_qntls,
  file = "wtd_ensemble_daily_qntls.rds"
)

saveRDS(
  object = wtd_ensemble_weekly_qntls,
  file = "wtd_ensemble_weekly_qntls.rds"
)

ensemble_model_rt_samples <- purrr::map_dfr(
  week_ending,
  function(week) {
    message("Week is ", week)
    idx <- grep(x = names(model_outputs), pattern = week)
    message("Working on models ", names(model_outputs)[idx])
    outputs <- purrr::map(model_outputs[idx], ~ .[["R_last"]])
    ## First Level is model, 2nd is country, 3rd is SI.
    ## TODO pick countries from inout
    countries <- names(outputs[[2]])
    names(countries) <- countries
    purrr::map_dfr(
      countries,
      function(country) {
        ## y is country specific output
        y <- purrr::map(outputs, ~ .[[country]])
        ## y has 2 components, one for each SI.
        ## Determine quantiles
        y_1 <- purrr::map(y, ~ .[[1]]) ## si_1
        y_2 <- purrr::map(y, ~ .[[2]]) ## si_1
        data.frame(
          si_1 = unlist(y_1),
          si_2 = unlist(y_2)
        )
      },
      .id = "country"
    )
  },
  .id = "model" ## this is really week ending, but to be able to resue prev code, i am calling it model
)

saveRDS(
  object = ensemble_model_rt_samples,
  file = "ensemble_model_rt_samples.rds"
)
