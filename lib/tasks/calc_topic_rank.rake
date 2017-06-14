namespace :calc_topic_rank do

  desc "Calculate topics weekly rank."
  task weekly: :environment do
    Topic.calc_weekly_ranks
  end

  desc "Calculate topics daily rank."
  task daily: :environment do
    Topic.calc_daily_ranks
  end
end
