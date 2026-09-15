-- 85Blends 2.4.0 — indexes required by price-alert delivery and latest-price lookup paths.
create index price_alert_deliveries_push_device_idx
  on private.price_alert_deliveries (push_device_id);

create index e85_price_reports_station_latest_idx
  on public.e85_price_reports (station_id, reported_at desc, created_at desc);