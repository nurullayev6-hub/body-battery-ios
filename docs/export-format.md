# Формат выгрузки «Резерв» (`rezerv-export-1`)

Файлы в закрытом репозитории пользователя:

- `rezerv/latest.json` — последние 7 дней, обновляется автоматически (не чаще раза в 30 минут).
- `rezerv/days/YYYY-MM-DD.json` — по одному файлу на день (история и новые дни).

Поля верхнего уровня: `schema`, `generated`, `timezone`, `dataUntil`, `profile` (age, weightKg, restingHR, hrvBaselineMs, maxHR), `days[]`, `hrvSDNN` ([время, мс]), `respiratoryRate`, `spo2` (%), `workouts[]`, `vo2max`.

`days[]`: `date`, `restingHR`, `reserve` (end/high/low/charged/drained/bySource), `minutesByState`, `avgStressAwakeRest`,
`series5min` (start, stepMin=5, hr[], steps[], reserve[], stress[], state — строка кодов S/R/L/M/H/A/-),
`sleep` (start, end, inBedMin, asleepMin, latencyMin, stagesMin, efficiency %, awakenings, hrvAvgMs, hrAvg, hrMin, respRate, score 0–100, scoreParts, reserveCharge, hypnogram5min — d/c/r/a по 5 минут).

`workouts[]`: type, start, durationMin, distanceKm, paceSecPerKm, speedKmh, avgHR, maxHR, kcal, trimp (Banister), effect, zonesMin[5] (от макс. пульса 50/60/70/80/90%), recovery1minBpm, cadence, elevGainM, splits[] (km, sec, hr), vo2maxEstimate, perMinute (hr[], speedMps[], cadence[]).

`vo2max`: estimate30d, apple[] ([время, значение] — Кардиофитнес Apple), runs[] ([время, оценка, устойчивых минут, км]).

Резерв — собственная приближённая модель (не Garmin/Firstbeat), формулы в `Rezerv/Engine/EnergyEngine.swift`.
