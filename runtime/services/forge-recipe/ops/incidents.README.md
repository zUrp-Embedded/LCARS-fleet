# Branche `incidents` — le registre du pilote

`work/system-incidents.json` : les incidents que le pilote a vus, par signature — compte,
première et dernière occurrence, escalade. Écrit par le système (`Fleet.Pilot.IncidentRegistry`),
fusionné avec sa copie locale à chaque synchronisation. Lisible par tous, à modifier à la main
seulement pour réparer un fichier corrompu.
