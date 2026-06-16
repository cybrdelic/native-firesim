# NIST FCD Methanol_1m_Pool_R1

Imported by scripts/import-nist-fcd-methanol-r1.ps1.

Source page: https://www.nist.gov/el/fcd/characteristics-1-m-methanol-pool-fire/methanol1mpoolr1
Raw CSV: https://www.nist.gov/fcd-s3?path=%2FHRR%2FASSET_FILES%2FMethanolPoolFire%2Fdata%2F1539886448_Methanol_1m_Pool_R1.csv
FCD DOI: https://doi.org/10.18434/mds2-2314
License/terms: https://www.nist.gov/open/license

This benchmark includes direct CSV channels for HRR, auxiliary HRR, exhaust mass flow, O2/CO2/CO volume fractions, radiant heat flux, and smoke extinction. It also includes derived massRemainingKg and smokeOpticalDepth columns.

alidation-targets.csv declares the first bounded CUDA-vs-NIST comparison envelopes. They are deliberately broad until calibration work tightens the model.

It intentionally does not claim thermocouple, IR-frame, or plume-height calibration because those are not present as numeric columns in this FCD CSV export.
