-- =====================================================================
--  Mellow George Perfumes — seed data
--  The business row + full product catalog (FOR HER, FOR HIM, Bundles).
--  Safe to re-run: uses stable slugs / SKUs with upsert.
-- =====================================================================

insert into public.businesses (id, name, slug, tagline, website, email, reseller_email, currency, country, city, free_delivery_threshold)
values (
  '11111111-1111-1111-1111-111111111111',
  'Mellow George Perfumes',
  'mellow-george',
  'Smell like a million. Pay like a person.',
  'https://www.mellowgeorge.shop',
  'hello@mellowgeorge.shop',
  'resellers@mellowgeorge.shop',
  'ZAR', 'South Africa', 'Johannesburg', 250
)
on conflict (slug) do update set
  tagline = excluded.tagline,
  website = excluded.website,
  reseller_email = excluded.reseller_email;

-- ---- FOR HER (blush line, R120 retail, rose accent) ----
insert into public.products (business_id, sku, name, slug, line, inspired_by, fragrance_family, character, retail_price, wholesale_price, recommended_sell_price, accent_color, emoji, sort_order)
values
 ('11111111-1111-1111-1111-111111111111','MG-HER-01','Mbali','mbali','her','Classic floral house','Floral','Fresh, feminine, South African soul',120,84,150,'#a03c5f','🌸',1),
 ('11111111-1111-1111-1111-111111111111','MG-HER-02','Lufuno','lufuno','her','Classic floral house','Floral Aldehyde','Warm and powdery with timeless elegance',120,84,150,'#a03c5f','🌸',2),
 ('11111111-1111-1111-1111-111111111111','MG-HER-03','Bonolo','bonolo','her','Fresh floral house','Fruity Floral','Light, playful, everyday wear',120,84,150,'#a03c5f','🌸',3),
 ('11111111-1111-1111-1111-111111111111','MG-HER-04','Velvet Rose','velvet-rose','her','YSL Black Opium','Oriental Floral','Coffee and rose wrapped in velvet — addictive',120,84,150,'#a03c5f','🌹',4),
 ('11111111-1111-1111-1111-111111111111','MG-HER-05','Dark Temptation','dark-temptation','her','Sensual oriental house','Dark Oriental','Bold, mysterious, unforgettable',120,84,150,'#a03c5f','🖤',5)
on conflict (sku) do nothing;

-- ---- FOR HIM (cream line, R120 retail, gold accent) ----
insert into public.products (business_id, sku, name, slug, line, inspired_by, fragrance_family, character, retail_price, wholesale_price, recommended_sell_price, accent_color, emoji, sort_order)
values
 ('11111111-1111-1111-1111-111111111111','MG-HIM-01','Grootman','grootman','him',null,'Aromatic Fougère','Bold, South African swagger — the one men reach for without thinking',120,84,150,'#b8943f','🧴',1),
 ('11111111-1111-1111-1111-111111111111','MG-HIM-02','Titan','titan','him',null,'Woody Aromatic','Strong, powerful, commanding — commands the room quietly',120,84,150,'#b8943f','🧴',2),
 ('11111111-1111-1111-1111-111111111111','MG-HIM-03','Legacy','legacy','him',null,'Woody Oriental','Sophisticated, long-lasting — for the man who leaves a mark',120,84,150,'#b8943f','🧴',3),
 ('11111111-1111-1111-1111-111111111111','MG-HIM-04','Dominus','dominus','him','Latin for "master"','Dark Oriental','Smoky, dark, authoritative — authority in a bottle',120,84,150,'#b8943f','🧴',4),
 ('11111111-1111-1111-1111-111111111111','MG-HIM-05','Obsidian','obsidian','him',null,'Aquatic Woody','Sharp, volcanic, modern — clean edge with deep warmth underneath',120,84,150,'#b8943f','🧴',5)
on conflict (sku) do nothing;

-- ---- BUNDLES ----
insert into public.products (business_id, sku, name, slug, line, character, retail_price, wholesale_price, recommended_sell_price, is_bundle, bundle_size, size_ml, accent_color, emoji, sort_order)
values
 ('11111111-1111-1111-1111-111111111111','MG-BND-01','Pocket Spray 10ml','pocket-spray-10ml','bundle','Take your scent anywhere',50,35,70,true,1,10,'#b8943f','🧴',1),
 ('11111111-1111-1111-1111-111111111111','MG-BND-02','Sample Vial 5ml','sample-vial-5ml','bundle','Try before you commit',20,12,30,true,1,5,'#b8943f','🧪',2),
 ('11111111-1111-1111-1111-111111111111','MG-BND-03','Twin Pack 2×50ml','twin-pack','bundle','Two full bottles, one great price',220,150,260,true,2,50,'#b8943f','🎁',3),
 ('11111111-1111-1111-1111-111111111111','MG-BND-04','Gift Set 3×10ml','gift-set','bundle','Three signature scents, gift-ready',120,80,150,true,3,10,'#b8943f','🎁',4),
 ('11111111-1111-1111-1111-111111111111','MG-BND-05','Trial Set 5×5ml','trial-set','bundle','Five scents to find your signature',95,60,120,true,5,5,'#b8943f','🧪',5)
on conflict (sku) do nothing;
