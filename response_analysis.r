# Response analysis for NGS2
# Author: Matt Hoover <matt_hoover@gallup.com>

# directory setup
if(Sys.info()['sysname'] == 'Darwin') {
    rm(list = ls())

    # Install packages that are required for this file
    list.of.packages <- c('foreign', 'reshape2')
    new.packages <- list.of.packages[!(list.of.packages %in%
                                       installed.packages()[, 'Package'])]
    if(length(new.packages)) {
        install.packages(new.packages)
    }
    lapply(list.of.packages, require, character.only = TRUE)
}

# renaming dictionaries
PANEL_VARNAMES <- c(
    'ExternalDataReference',
    'DEMO_GENDER',
    'DEMO_AGE',
    'demo_division',
    'demo_region',
    'DEMO_EDUCATION_NEW',
    'DEMO_EMPLOYMENT_STATUS',
    'MEMBERSHIP_START_DATE',
    'MEMBERSHIP_STATUS'
)

# function definitions
bb_data_merge <- function(login, training, play = NULL, decision = NULL,
                          scores = NULL, prefix = 'bb') {
    # merge various breadboard summary pieces together
    tmp <- merge(login, training, on = c('pid', 'date', 'game'), all = TRUE)
    tmp <- merge(tmp , play, on = c('pid', 'date', 'game'), all = TRUE)
    tmp <- merge(tmp, decision, on = c('pid', 'date', 'game'), all = TRUE)
    tmp <- merge(tmp, scores, on = c('pid', 'date', 'game'), all = TRUE)
    names(tmp) <- paste(prefix, names(tmp), sep = '_')
    return(tmp)
}

bb_decision_timing <- function(d, exp1 = FALSE) {
    # calculate the average time (across rounds) it takes a player to make a
    # decision
    if(exp1) {
        tmp <- dcast(subset(d, event == 'cooperationEvent'),
                     id + datetime ~ data.name, value.var = 'data.value')
    } else {
        tmp <- dcast(subset(d, event == 'CooperationDecision'),
                     id + datetime ~ data.name, value.var = 'data.value')
        names(tmp)[which(names(tmp) == 'curRound')] <- 'round'
    }
    tmp <- tmp[grepl('^[0-9]', tmp$round), ]
    tmp$round <- as.numeric(tmp$round)
    res <- do.call(rbind, lapply(split(tmp, tmp$round), function(x) {
        start <- min(x$datetime)
        x <- subset(x, !grepl('^dummy', pid))
        if(exp1) {
            return(data.frame(pid = x$pid, round = unique(x$round),
                              secs = x$datetime - start))
        } else {
            return(do.call(rbind, lapply(split(x, x$pid), function(y) {
                return(data.frame(pid = unique(y$pid), round = unique(y$round),
                                  secs = unique(y$datetime - start)))
            })))
        }
    }))
    res <- aggregate(res$secs, by = list(res$pid), mean, na.rm = TRUE)
    names(res) <- c('pid', 'secs_to_decision')
    return(data.frame(pid = res$pid, date = unique(d$exp_date),
                      game = unique(d$game),
                      secs_to_decision = res$secs_to_decision,
                      stringsAsFactors = FALSE))
}

bb_end_scores <- function(d, recast = FALSE) {
    # take a breadboard dataset and determine final score by participant
    tmp <- subset(d, event == 'FinalScore')
    if(recast) {
        tmp <- dcast(tmp, id + datetime ~ data.name, value.var = 'data.value')
        tmp <- tmp[, c('id', 'datetime', 'pid', 'score')]
        names(tmp)[3] <- 'playerid'
    } else {
        tmp <- tmp[, c('id', 'datetime', 'data.name', 'data.value')]
        names(tmp)[3:4] <- c('playerid', 'score')
    }
    return(data.frame(pid = tmp$playerid, date = unique(d$exp_date),
                      game = unique(d$game), end_score = as.numeric(tmp$score),
                      stringsAsFactors = FALSE))
}

bb_gameplay <- function(d, exp1 = FALSE) {
    # determines rounds played per person
    if(exp1) {
        tmp <- dcast(subset(d, event == 'cooperationEvent'),
                     id + datetime ~ data.name, value.var = 'data.value')
        tmp <- suppressWarnings(tmp[!grepl('^dummy', tmp$pid) &
                                    !is.na(as.numeric(tmp$round)), ])
        tmp$round <- as.numeric(tmp$round)
        tmp <- dcast(tmp, pid ~ round, fun.aggregate = length)
        names(tmp)[2:ncol(tmp)] <- paste0('r', names(tmp)[2:ncol(tmp)])
    } else {
        tmp <- dcast(subset(d, event == 'CooperationDecision'),
                     id + datetime ~ data.name, value.var = 'data.value')
        tmp <- tmp[!grepl('^dummy', tmp$pid), ]
        names(tmp)[which(names(tmp) == 'curRound')] <- 'round'
        tmp$round <- as.numeric(tmp$round)
        tmp <- dcast(tmp, pid ~ round, fun.aggregate = length)
        tmp[, 2:ncol(tmp)] <- apply(tmp[, 2:ncol(tmp)], 2, function(x) {
            ifelse(x > 0, 1, 0)
        })
        names(tmp)[2:ncol(tmp)] <- paste0('r', names(tmp)[2:ncol(tmp)])
    }
    res <- data.frame(tmp, date = unique(d$exp_date), game = unique(d$game),
                      stringsAsFactors = FALSE)
    return(melt(res, id.vars = c('pid', 'date', 'game')))
}

bb_login <- function(d, end_time) {
    # create unique logins for players, using the last login prior to final
    # scores being recorded for a game
    tmp <- dcast(subset(d, event == 'clientLogIn'),
                 id + datetime ~ data.name, value.var = 'data.value')
    tmp <- tmp[order(tmp$datetime, decreasing = TRUE), ]
    tmp <- tmp[tmp$datetime <= end_time, ]
    tmp <- tmp[!duplicated(tmp$clientId), ]
    return(data.frame(pid = tmp$clientId, ip_address = tmp$ipAddress,
                      date = unique(d$exp_date), game = unique(d$game),
                      logged_in = 1, stringsAsFactors = FALSE))
}

bb_passed_training <- function(d, experiment = c(1, 2)) {
    # calculate which players passed training
    if(experiment == 1) {
        tmp <- dcast(subset(d, event == 'cooperationEvent'),
                     id + datetime ~ data.name, value.var = 'data.value')
        tmp <- subset(tmp, !grepl('^dummy', pid) & round == 'p1')
        return(data.frame(pid = tmp$pid, date = unique(d$exp_date),
                          game = unique(d$game), passed_training = 1,
                          stringsAsFactors = FALSE))
    } else {
        qcast <- dcast(subset(d, grepl('^q', event)),
                       id + datetime ~ data.name, value.var = 'data.value')
        q_success <- do.call(rbind, lapply(split(qcast, qcast$pid), function(x) {
            res <- apply(x[, 3:ncol(x)], 2, function(y) {
                return(y[!is.na(y)])
            })
            res <- sum(res %in% c('randomly', 'net_total', 'leave_neighborhood',
                                  'pay_100_gain_100')) / 4
            return(data.frame(pid = unique(x$pid), frac_q_correct = res))
        }))
        tmp <- dcast(subset(d, event == 'ChooseGroup'),
                     id + datetime ~ data.name, value.var = 'data.value')
        return(merge(
            data.frame(pid = tmp$pid, date = unique(d$exp_date),
                       game = unique(d$game), passed_training = 1,
                       stringsAsFactors = FALSE),
            q_success,
            on = 'pid'
        ))
    }
}

convert_time <- function(d) {
    # convert a vector of breadboard date strings to datetime
    return(strptime(d, '%Y-%m-%d %H:%M:%S'))
}

get_bb_id <- function(var) {
    do.call(c, lapply(strsplit(var, '/'), function(x) {
        l <- length(x)
        return(x[l])
    }))
}

load_bb_data <- function(dir) {
    files <- list.files(dir)
    res <- data.frame()
    for(i in 1:length(files)) {
        fparts <- strsplit(files[i], '_')[[1]]
        tmp <- read.csv(paste(dir, files[i], sep = '/'), header = TRUE,
                        sep = ',', stringsAsFactors = FALSE)
        tmp$exp_date <- fparts[2]
        tmp$game <- fparts[1]
        tmp$source <- paste(fparts[1:2], collapse = '_')
        res <- rbind(res, tmp)
    }
    return(res)
}

# load all data
emp <- read.csv('empanelment_cleaned.csv', header = TRUE, sep = ',',
                stringsAsFactors = FALSE)
panel <- read.csv('data/WORLD_LAB_PANEL_DEMOS.csv', header = TRUE, sep = ',',
                  stringsAsFactors = FALSE)
bb_ids <- read.csv('data/oms_url_upload_20170821_1145.txt', header = TRUE,
                   sep = '\t', stringsAsFactors = FALSE)
times <- read.csv('data/experiment_signup_list_20170907_0700.csv', header = TRUE,
                  sep = ',', stringsAsFactors = FALSE)
bb1 <- load_bb_data('NGS2-Cycle1-Experiment1/data')
bb2 <- load_bb_data('NGS2-Cycle1-Experiment2/data')

# 1. deal with survey responses
d <- emp
d$source <- 'empanelment'

# 2. bring in breadboard ids for those that went from empanelment to experiment
# parse out breadboard id
bb_ids$bb_id <- get_bb_id(bb_ids$ROUTER_URL)

# merge in breadboard ids
d <- merge(
    d,
    bb_ids[, c('EMPLOYEE_KEY_VALUE', 'bb_id')],
    by.x = 'ExternalDataReference',
    by.y = 'EMPLOYEE_KEY_VALUE',
    all.x = TRUE
)

# 3. deal with the experiment timing data
# drop extraneous rows
times <- times[times$EXPERIMENT_ID != 'nu', ]
times$EXPERIMENT_ID <- as.numeric(times$EXPERIMENT_ID)

times <- times[!duplicated(times[, c('ExternalDataReference', 'EXPERIMENT_ID')]), ]

# reshape experiment signups to wide
exp_signup <- dcast(times, ExternalDataReference ~ EXPERIMENT_ID, length)
rd_starts <- grep('^[0-9]', names(exp_signup))
names(exp_signup)[rd_starts] <- paste0('exp', names(exp_signup)[rd_starts])

# merge timing data into empanelment
d <- merge(
    d,
    exp_signup,
    by = 'ExternalDataReference',
    all.x = TRUE
)

# 4. add in panel demographics
panel <- panel[, PANEL_VARNAMES]
names(panel) <- paste('panel', names(panel), sep = '_')

# redo datetime variable from numeric
panel$panel_MEMBERSHIP_START_DATE <- strptime(panel$panel_MEMBERSHIP_START_DATE,
                                              '%m/%d/%Y')

# merge panel in with existing data
d <- merge(
    d,
    panel,
    by.x = 'ExternalDataReference',
    by.y = 'panel_ExternalDataReference',
    all = TRUE
)
d$source <- ifelse(is.na(d$source), 'panel', d$source)

# 5. bring in breadboard data
# create datetimes from timestamps
bb1$datetime <- convert_time(bb1$datetime)
bb2$datetime <- convert_time(bb2$datetime)

# identify logins
bb1_login <- do.call(rbind, lapply(split(bb1, bb1$source), function(x) {
    return(bb_login(x, x$datetime[x$event == 'initStart']))
}))
bb2_login <- do.call(rbind, lapply(split(bb2, bb2$source), function(x) {
    return(bb_login(x, x$datetime[x$event == 'StepStart' &
                                  x$data.value == 'initStep']))
}))

# determine who passed training
bb1_training <- do.call(rbind, lapply(split(bb1, bb1$source), function(x) {
    return(bb_passed_training(x, experiment = 1))
}))
bb2_training <- do.call(rbind, lapply(split(bb2, bb2$source), function(x) {
    return(bb_passed_training(x, experiment = 2))
}))

# identify game play through rounds
bb1_play <- do.call(rbind, lapply(split(bb1, bb1$source), function(x) {
    return(bb_gameplay(x, exp1 = TRUE))
}))
bb1_play <- dcast(bb1_play, pid + date + game ~ variable, value.vars = 'value')
bb2_play <- do.call(rbind, lapply(split(bb2, bb2$source), function(x) {
    return(bb_gameplay(x, exp1 = FALSE))
}))
bb2_play <- dcast(bb2_play, pid + date + game ~ variable, value.vars = 'value')

# identify time for player decisions across rounds
bb1_decision <- do.call(rbind, lapply(split(bb1, bb1$source), function(x) {
    return(bb_decision_timing(x, exp1 = TRUE))
}))
bb2_decision <- do.call(rbind, lapply(split(bb2, bb2$source), function(x) {
    return(bb_decision_timing(x, exp1 = FALSE))
}))

# identify ending scores
bb1_scores <- do.call(rbind, lapply(split(bb1, bb1$source), function(x) {
    return(bb_end_scores(x, recast = FALSE))
}))
bb2_scores <- do.call(rbind, lapply(split(bb2, bb2$source), function(x) {
    return(bb_end_scores(x, recast = TRUE))
}))

# create final breadboard datasets
bb1_summary <- bb_data_merge(bb1_login, bb1_training, bb1_play,
                             bb1_decision, bb1_scores, prefix = 'bb1')
bb2_summary <- bb_data_merge(bb2_login, bb2_training, bb2_play,
                             bb2_decision, bb2_scores, prefix = 'bb2')

# merge breadboard summaries to data
d <- merge(d, bb1_summary, by.x = 'bb_id', by.y = 'bb1_pid', all = TRUE)
d <- merge(d, bb2_summary, by.x = 'bb_id', by.y = 'bb2_pid', all = TRUE)
d$source <- ifelse(is.na(d$source), 'bb', d$source)

# 7. derive variables for analysis
# d$days_with_panel <- as.numeric(
#     as.POSIXct('2017-07-12') -
#     d$panel_MEMBERSHIP_START_DATE
# )
d$began_empanelment <- ifelse(d$source == 'empanelment', 1, 0)
d$stop_prior_to_consent <- ifelse(d$began_empanelment == 1 & is.na(d$Q3_consent), 1,
                                  ifelse(d$began_empanelment == 1, 0, NA))
d$stop_at_consent <- ifelse(d$stop_prior_to_consent == 0 & is.na(d$Q6_1_extravert),
                            1, ifelse(d$stop_prior_to_consent == 0, 0, NA))
relevant_questions <- grep('Q([6-9]|[1-2][0-9]|3[0-8])_.*[^REV]$', names(d))
start_point <- which(relevant_questions == which(names(d) == 'Q6_1_extravert'))
d$stop_at_other_point <- apply(d[, relevant_questions], 1, function(x) {
    ifelse(is.na(x[start_point]), NA,
           ifelse(length(x[!is.na(x)]) / length(relevant_questions) < .9, 1, 0))
})
d$completed_empanelment <- ifelse(!is.na(d$Q39_send_survey_invites), 1,
                                  ifelse(d$source == 'empanelment', 0, NA))

d$experiment_signup <- apply(d[, grep('^exp', names(d))], 1, function(x) {
    return(ifelse(sum(x, na.rm = TRUE) > 0, 1, 0))
})

# write data to disk
write.csv(d, file = 'response_analysis_clean.csv', row.names = FALSE, na = '')
