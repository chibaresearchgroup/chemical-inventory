-- Adds a cached PubChem CID per chemical so structure search can use
-- PubChem's own substructure-search index instead of requiring every
-- imported row to carry a hand-drawn molfile (which the bulk CSV import
-- never populates).
alter table chemicals add column if not exists pubchem_cid bigint;
create index if not exists chemicals_pubchem_cid_idx on chemicals(pubchem_cid) where pubchem_cid is not null;
