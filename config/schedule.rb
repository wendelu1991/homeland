
every :hour do
  rake "calc_topic_rank:weekly"
end

every 10.minutes do
  rake "calc_topic_rank:daily"
end