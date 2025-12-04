#!/bin/bash

# Script pour mettre à jour les métadonnées des produits Stripe
# Change category de "apparel" à "bathub"

echo "Récupération des produits avec category=apparel..."

# Récupérer tous les produits actifs
stripe products list --limit 100 | \
jq -r '.data[] | select(.metadata.category == "apparel") | .id' | \
while read product_id; do
  echo "Mise à jour du produit: $product_id"

  # Mettre à jour les métadonnées
  stripe products update "$product_id" \
    --metadata category=bathub

  if [ $? -eq 0 ]; then
    echo "✓ Produit $product_id mis à jour avec succès"
  else
    echo "✗ Erreur lors de la mise à jour du produit $product_id"
  fi

  # Petite pause pour éviter les rate limits
  sleep 0.5
done

echo "Mise à jour terminée!"
