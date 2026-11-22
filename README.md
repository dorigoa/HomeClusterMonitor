Execute these commands:
```bash
sudo apt-get update && sudo apt-get install -y curl gnupg ca-certificates
curl -fsSL https://repos.influxdata.com/influxdata-archive.key | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/influxdata-archive.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main" | sudo tee /etc/apt/sources.list.d/influxdata.list
sudo apt-get update && sudo apt-get install -y telegraf
```

Create the file `/etc/telegraf/telegraf.conf`:
```bash
[global_tags]
[agent]
  interval = "10s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"
  flush_interval = "10s"
  flush_jitter = "0s"
  precision = "0s"
[[inputs.cpu]]
  percpu = true
  totalcpu = true
  collect_cpu_time = false
  report_active = false
  core_tags = false
[[inputs.kernel]]
[[inputs.mem]]
[[inputs.processes]]
[[inputs.swap]]
[[inputs.system]]

[[outputs.influxdb]]
  urls = ["http://localhost:8086"]
  database = "telegraf"
  skip_database_creation = true

[[outputs.file]]
  files = ["stdout"]
  data_format = "influx"
```
Execute:
```bash
systemctl enable --now telegraf
```
