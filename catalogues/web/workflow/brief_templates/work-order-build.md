<!-- Date: 2026-08-10 — Gabarit de brief. Il est remis TEL QUEL a l'agent (l'en-tete HTML est retire au rendu).
     Les jetons {{...}} sont remplis par le runtime : gardez-les, deplacez-les, mais ne les
     inventez pas — un jeton inconnu reste tel quel dans le texte remis a l'agent.
     Cette prose est du reglage : c'est ici qu'on ajuste ce qu'un producteur comprend de sa
     mission, sans toucher au code. -->
# Ordre de mission — {{role}} — ticket #{{issue}}

## Ce qui est demandé

{{brief_body}}

*Source : {{brief_source}}*

## Comment tu livres

Fais le travail dans ton espace de travail, puis `git add` et `git commit`.

**Le système pousse à ta place** et ouvre la proposition de fusion. Tu ne pousses pas.

`submit_result` clôt ta tâche. **Ton livrable, ce sont tes commits** — ne remets pas le contenu des
fichiers dans le résultat, ils sont déjà commités.

## Ta voix

Le résultat que tu rends **doit** porter un champ `summary` :

```
{"summary": "Ajouté X ; choisi Y plutôt que Z parce que ..."}
```

Ce résumé est court, en markdown, et il dit **ce que tu as fait et ce que tu as décidé** — pas ce que
contiennent tes fichiers. Le système le publie sur la proposition de fusion : c'est ta seule voix
auprès de qui relira.

**Si tu es bloqué** — une information manque, une décision n'a pas été prise — ne devine pas. Ajoute
`"blocked": true` à côté de ton `summary`, et que le `summary` dise **précisément ce qui manque** :

```
{"blocked": true, "summary": "Le ticket ne dit pas ce qui s'affiche quand la liste est vide."}
```

Le système remonte alors à un humain. Aucun commit n'est attendu de toi dans ce cas.
