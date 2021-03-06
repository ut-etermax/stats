# WARNING! This is messy --------------------------------------------------

# df_time_played is the worst ---------------------------------------------

get_rounds_interval <- function(df_match_events) {
  df_valid_rounds <- df_match_events %>%
    group_by(
      round
    ) %>%
    summarise(
      round_start = min(asctime),
      round_end = asctime[
        if_else(
          any(grepl("Exit", message)),
          which.max(grepl("Exit", message)),
          NA_integer_
        )
        ]
    ) %>%
    mutate(
      round_end = coalesce(round_end, lead(round_start))
    ) %>%
    ungroup()
  
  lubridate::interval(df_valid_rounds$round_start, df_valid_rounds$round_end)
}

get_df_flags_won <- function(df_match_events) {
  df_match_events %>%
    filter(event_type == 'flag_captured') %>%
    select(asctime, capturing_team = player_team)
}

get_df_sessions <- function(df_raw_data, df_flags_won) {
  df_raw_data %>%
    group_by(
      player_guid,
      player_session_id,
      player_team
    ) %>%
    summarise(
      session_start = min(asctime),
      session_end = max(asctime)
    ) %>%
    group_by(player_guid) %>%
    mutate(
      session_end = coalesce(lead(session_start), session_end)
    ) %>%
    ungroup() %>%
    filter(player_team %in% c('red', 'blue')) %>%
    mutate(
      # session_end = coalesce(session_end, max(session_end, na.rm = TRUE))
      # ,
      flags_won = list(player_team, session_start, session_end) %>%
        pmap_int(
          ~filter(
            df_flags_won,
            capturing_team == ..1,
            asctime >= ..2,
            asctime < ..3
          ) %>%
            NROW()
        ),
      flags_lost = list(player_team, session_start, session_end) %>%
        pmap_int(
          ~filter(
            df_flags_won,
            capturing_team != ..1,
            asctime >= ..2,
            asctime < ..3
          ) %>%
            NROW()
        )
    )
}

get_time_played <- function(round_interval, session_interval) {
  lubridate::intersect(round_interval, session_interval) %>%
    as.period(unit = "seconds") %>%
    second()
}

get_df_time_played <- function(df_raw_data, df_match_events) {
  df_flags_won <- get_df_flags_won(df_match_events)
  df_sessions <- get_df_sessions(df_raw_data, df_flags_won)
  rounds_interval <- get_rounds_interval(df_match_events)
  
  df_time_played <- df_sessions %>%
    mutate(
      round_1_time_played = get_time_played(
        rounds_interval[1],
        lubridate::interval(session_start, session_end)
      ),
      round_2_time_played = get_time_played(
        rounds_interval[2],
        lubridate::interval(session_start, session_end)
      )
    ) %>%
    filter(player_session_id > 0) %>%
    group_by(
      player_guid
    ) %>%
    summarise_at(
      vars(starts_with("round"), flags_won, flags_lost),
      sum,
      na.rm = TRUE
    ) %>%
    ungroup() %>%
    mutate(
      total_time_played = round_1_time_played + round_2_time_played
    ) %>%
    select(
      player_guid,
      round_1_time_played,
      round_2_time_played,
      total_time_played,
      flags_won,
      flags_lost
    ) %>%
    arrange(-flags_won) %>%
    filter(total_time_played > 0)
}

# Stuff -------------------------------------------------------------------

get_df_kills <- function(df_kill_events) {
  df_kill_events %>%
    filter(killer_guid != 'NONE') %>%
    
    # No contar team kills
    filter(!is_team_kill) %>%
    
    count(killer_guid) %>%
    select(player_guid = killer_guid, kills = n) %>%
    arrange(-kills)
}

get_df_deaths <- function(df_kill_events) {
  df_kill_events %>%
    count(victim_guid) %>%
    select(player_guid = victim_guid, deaths = n) %>%
    arrange(-deaths)
}

get_df_player_team_flags <- function(df_time_played) {
  df_time_played %>%
    select(
      player_guid,
      flags_won,
      flags_lost
    )
}

# Intermediate results ----------------------------------------------------

add_player_capture_attemps <- function(df, df_flag_events) {
  df %>%
    left_join(
      df_flag_events %>%
        filter(event_type %in% c('flag_dropped', 'flag_capture_time')) %>%
        distinct(player_guid, round, flag_team, flag_id) %>%
        group_by(player_guid) %>%
        summarize(flag_capture_attempts = n()) %>%
        ungroup(),
      by = 'player_guid'
    ) %>%
    mutate_at(
      'flag_capture_attempts',
      ~coalesce(.x, 0L)
    )
}

add_player_flag_assists <- function(df, df_flag_events) {
  df_flag_assists <- df_flag_events %>%
    filter(event_type == 'flag_dropped') %>%
    inner_join(
      df_flag_events %>%
        filter(event_type == 'flag_capture_time') %>%
        mutate(
          flag_capture_time_start = asctime - capture_time_secs
        ) %>%
        select(
          round,
          flag_team,
          flag_id,
          flag_capturer_guid = player_guid,
          flag_capture_time_start,
          flag_capture_time_end = asctime
        ),
      by = c('round', 'flag_team', 'flag_id')
    ) %>%
    filter(
      player_guid != flag_capturer_guid,
      asctime >= flag_capture_time_start,
      asctime <= flag_capture_time_end
    ) %>%
    group_by(player_guid) %>%
    summarize(
      flag_assists = n()
    ) %>%
    ungroup()
  
  df %>%
    left_join(
      df_flag_assists,
      by = 'player_guid'
    ) %>%
    mutate_at(
      'flag_assists',
      ~coalesce(.x, 0L)
    )
}

get_df_flag_stats <- function(
  df_flag_events,
  df_time_played,
  df_match_players
) {
  df_match_players %>%
    select(player_guid) %>%
    left_join(
      df_flag_events %>%
        count(event_type, player_guid) %>%
        ungroup(),
      by = 'player_guid'
    ) %>%
    complete(event_type, player_guid, fill = list(n = 0L)) %>%
    filter(!is.na(event_type)) %>%
    
    spread(
      key = event_type,
      value = n
    ) %>%
    
    mutate(
      flag_capture_time = if('flag_capture_time' %in% names(.)) flag_capture_time else 0
    ) %>%
    
    add_player_capture_attemps(df_flag_events) %>%
    add_player_flag_assists(df_flag_events) %>%
    left_join(
      get_df_player_team_flags(df_time_played),
      by = 'player_guid'
    ) %>%
    
    mutate(
      result = case_when(
        flags_won > flags_lost ~ 'WIN',
        flags_won == flags_lost ~ 'DRAW',
        TRUE ~ 'LOSE'
      )
    ) %>%
    select(
      player_guid,
      flags_captured = flag_capture_time,
      flag_assists,
      flags_returned = flag_returned,
      flag_capture_attempts,
      flags_won,
      flags_lost,
      result
    )
}

get_df_kills_stats <- function(
  df_kill_events,
  df_time_played,
  df_match_players
) {
  df_raw_kill_stats <- df_match_players %>%
    select(player_guid) %>%
    left_join(
      get_df_kills(df_kill_events),
      by = 'player_guid'
    ) %>%
    left_join(
      get_df_deaths(df_kill_events),
      by = 'player_guid'
    ) %>%
    left_join(
      df_time_played %>%
        select(player_guid, total_time_played),
      by = 'player_guid'
    )
  
  df_raw_kill_stats %>%
    replace_na(list(
      kills = 0L,
      deaths = 0L
    )) %>%
    mutate(
      # kills = coalesce(kills, 0L),
      kd_ratio = round(kills / deaths, 2) %>% coalesce(0),
      kills_per_minute = round(kills * 60 / total_time_played, 2)
    ) %>%
    
    mutate(
      total_time_played = format_elapsed_time(total_time_played)
    ) %>%
    
    select(
      player_guid,
      kills,
      deaths,
      kd_ratio,
      kills_per_minute,
      total_time_played
    )
}

# Exported ----------------------------------------------------------------

## TODO: Get rid of df_match_events dependency 
get_df_match_stats <- function(
  df_kill_events,
  df_flag_events,
  df_time_played,
  df_match_players
) {
  df_raw_match_stats <- inner_join(
    get_df_kills_stats(df_kill_events, df_time_played, df_match_players),
    get_df_flag_stats(df_flag_events, df_time_played, df_match_players),
    by = 'player_guid'
  )
  
  df_match_players %>%
    inner_join(
      df_raw_match_stats,
      by = 'player_guid'
    ) %>%
    select(-player_guid) %>%
    select(
      player_name,
      total_time_played,
      everything()
    ) %>%
    arrange(-kills_per_minute, -kd_ratio)
}
