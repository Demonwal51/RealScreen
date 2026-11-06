-- EcranReel : shows the player's real screen on the screens of the Gaming activity (Spirit City: Lofi Sessions).
-- The screens are the desk monitor and every handheld console. Their screen has its own material slot, recognised
-- by the game's original material, so the casing keeps its look. The picture itself comes from ecran_capture.dll,
-- which writes into the render target created here (recognised by its odd size).
-- Everything is found from this script's own place: the game can be installed anywhere.
local function dossier_du_mod()
    local ok, source = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and source then
        local d = source:gsub("^@", ""):gsub("\\", "/"):match("^(.*/)Scripts/[^/]*$")
        if d then return d end
    end
    return "ue4ss/Mods/EcranReel/"  -- the game's working folder is Binaries/Win64
end
local DOSSIER_MOD = dossier_du_mod()

-- The test bridge exists only on a development install: dev.txt holds its folder. A released mod has no such file.
local DIR = nil
do
    local f = io.open(DOSSIER_MOD .. "dev.txt", "r")
    if f then
        DIR = f:read("*l")
        f:close()
    end
end
local ORDRES = DIR and (DIR .. "ordres.txt")
local RESULTATS = DIR and (DIR .. "resultats.txt")
local JOURNAL = (DIR or DOSSIER_MOD) .. "journal.txt"
os.remove(JOURNAL)

local MATERIAU = "/Engine/EngineMaterials/Widget3DPassThrough_Opaque.Widget3DPassThrough_Opaque"
local PARAM = "SlateUI"
local MARQUE_NOTRE = "Widget3DPassThrough"
local LARGEUR, HAUTEUR = 1279, 721
local FORMAT_RGBA8_SRGB = 3
local ACTIVITE_JOUER = 14
-- The kinds of screen in the game: what their mesh is called, and the material that marks the screen on it.
local FAMILLES = {
    { id = "consoles", maillages = { "Computer_Monitor", "Handheld" }, materiaux = { "M_FlipbookAnimated_Goopii", "MI_GamingSreenStatic" } },
    { id = "portable", maillages = { "Laptop" }, materiaux = { "LaptopScreen" } },
    { id = "tablette", maillages = { "DrawingTablet_01" }, materiaux = { "DrawingTablet_Screen" } },
}
local MAILLAGES, MATERIAUX_ECRAN = {}, {}
for _, famille in ipairs(FAMILLES) do
    for _, texte in ipairs(famille.maillages) do MAILLAGES[#MAILLAGES + 1] = texte end
    for _, texte in ipairs(famille.materiaux) do MATERIAUX_ECRAN[#MATERIAUX_ECRAN + 1] = texte end
end

-- The places the player can set: an activity of the game, and the screens seen during it. Each one keeps its own settings.
-- Names come from the game's own text table, in its language; these are only a fallback if a game update moves it.
local TABLE_TEXTES_JEU = "/Game/Core_Sessions/ST_Localization.ST_Localization"
local LIEUX = {
    { id = "jouer", famille = "consoles", activites = { [14] = true }, cle_nom = "Activity_Gaming",
      noms = { en = "Gaming", fr = "Jouer", it = "Giocare", de = "Zocken", es = "Videojuegos", pt = "Jogar", ja = "ゲーム", zh = "打游戏", ko = "게임하기", ru = "Игры" } },
    { id = "clavarder", famille = "portable", activites = { [2] = true }, cle_nom = "Activity_Typing",
      noms = { en = "Typing", fr = "Clavarder", it = "Digitare", de = "Tippen", es = "Escribiendo", pt = "Digitar", ja = "タイピング", zh = "打字", ko = "타이핑", ru = "Печать" } },
    { id = "naviguer", famille = "portable", activites = { [5] = true }, cle_nom = "Activity_Browsing",
      noms = { en = "Browsing", fr = "Naviguer", it = "Sfogliare", de = "Suchen", es = "Navegar por internet", pt = "Navegando", ja = "ネット", zh = "浏览网页", ko = "브라우징", ru = "Просмотр" } },
    { id = "dessiner", famille = "tablette", activites = { [4] = true }, cle_nom = "Activity_Drawing",
      noms = { en = "Drawing", fr = "Dessiner", it = "Disegno", de = "Zeichnen", es = "Dibujar", pt = "Desenho", ja = "お絵描き", zh = "绘画", ko = "그리기", ru = "Рисование" } },
}
local LIEU_PAR_ID = {}
for _, lieu in ipairs(LIEUX) do LIEU_PAR_ID[lieu.id] = lieu end
local LIEU_COURANT = nil

local function lieu_de_activite(activite)
    for _, lieu in ipairs(LIEUX) do
        if lieu.activites[activite] then return lieu end
    end
    return nil
end
local TOURS_ENTRE_BALAYAGES = 30

local DERNIERE_ACTIVITE, DUREE_BALAYAGE_MS = nil, 0
local CIBLE, INSTANCE, CARTE = nil, nil, nil
local MODULE_CHARGE, ACTIF = false, false
local ECRANS, CONNUS = {}, {}
local MENU_DIAG = { remis = 0, sans_origine = 0 }
local ORIGINE_PAR_MAILLAGE = {}
local TOUR = 0
local PIRE_TOUR_MS = 0
local TICKS = 0
local gerer_mains = nil
local FRAPPE = { marche = false, courant = nil, par_avatar = {} }  -- the hands on the laptop, see "hands on the laptop"

-- ---------------------------------------------------------------- settings (ecran_reel.ini, shared with the DLL)

local CONFIG = { source = "ecran", numero = "1", images_par_seconde = "30", mains = "0", video_son = "1", fenetre_titre = "", fenetre_exe = "", video = "" }
local ORDRE_CONFIG = { "source", "numero", "images_par_seconde", "mains", "video_son", "fenetre_titre", "fenetre_exe", "video" }

-- What each place shows. The plain keys above are what the DLL reads: the settings of the place on screen right now.
local CLES_LIEU = { "source", "numero", "video_son", "fenetre_titre", "fenetre_exe", "video" }
local REGLAGES_LIEU = {}
for _, lieu in ipairs(LIEUX) do
    REGLAGES_LIEU[lieu.id] = { source = "aucune", numero = "1", video_son = "1", fenetre_titre = "", fenetre_exe = "", video = "" }
end
REGLAGES_LIEU.jouer.source = "ecran"  -- out of the box, Gaming shows the first monitor

local function lire_config()
    local f = io.open(DOSSIER_MOD .. "ecran_reel.ini", "r")
    if not f then return end
    for ligne in f:lines() do
        local cle, valeur = ligne:match("^([%w_]+)=(.*)$")
        if cle then
            valeur = valeur:gsub("\r$", "")
            local id, sous_cle = cle:match("^(%l+)_(.+)$")
            if id and REGLAGES_LIEU[id] and REGLAGES_LIEU[id][sous_cle] ~= nil then
                REGLAGES_LIEU[id][sous_cle] = valeur
            elseif CONFIG[cle] ~= nil then
                CONFIG[cle] = valeur
            end
        end
    end
    f:close()
end

-- The DLL shows the settings of the place on screen.
local function appliquer_lieu()
    if not LIEU_COURANT then return end
    local r = REGLAGES_LIEU[LIEU_COURANT.id]
    for _, cle in ipairs(CLES_LIEU) do CONFIG[cle] = r[cle] end
end

-- Replaced by a rename: the DLL never reads half a file.
local function ecrire_config()
    local chemin = DOSSIER_MOD .. "ecran_reel.ini"
    local f = io.open(chemin .. ".tmp", "w")
    if not f then return end
    f:write("; EcranReel. Reglages modifiables dans le jeu : Options, General.\n[ecran]\n")
    for _, cle in ipairs(ORDRE_CONFIG) do f:write(cle .. "=" .. CONFIG[cle] .. "\n") end
    for _, lieu in ipairs(LIEUX) do
        for _, cle in ipairs(CLES_LIEU) do f:write(lieu.id .. "_" .. cle .. "=" .. REGLAGES_LIEU[lieu.id][cle] .. "\n") end
    end
    f:close()
    os.remove(chemin)
    os.rename(chemin .. ".tmp", chemin)
end


local function journal(texte)
    local f = io.open(JOURNAL, "a")
    if f then
        f:write(os.date("%H:%M:%S ") .. tostring(texte) .. "\n")
        f:close()
    end
end

local function repondre(lignes)
    local f = io.open(RESULTATS .. ".tmp", "w")
    if not f then return end
    f:write(table.concat(lignes, "\n") .. "\nFIN\n")
    f:close()
    os.remove(RESULTATS)
    os.rename(RESULTATS .. ".tmp", RESULTATS)
end

local function nom(objet)
    if objet == nil then return "nil" end
    local ok, v = pcall(function()
        if not objet:IsValid() then return "invalide" end
        return objet:GetFullName()
    end)
    return ok and v or ("erreur:" .. tostring(v))
end

local function contient(texte, motifs)
    for _, m in ipairs(motifs) do
        if texte:find(m, 1, true) then return true end
    end
    return false
end

local function fichier_existe(chemin)
    local f = io.open(chemin, "r")
    if f then f:close(); return true end
    return false
end

local function valide(objet)
    return objet ~= nil and objet:IsValid()
end

-- ---------------------------------------------------------------- capture module

local function regler_actif(valeur)
    if valeur == ACTIF then return end
    ACTIF = valeur
    if valeur then
        local f = io.open(DOSSIER_MOD .. "actif.txt", "w")
        if f then f:close() end
    else
        os.remove(DOSSIER_MOD .. "actif.txt")
    end
    journal("capture " .. (valeur and "active" or "en pause"))
end

local function charger_module()
    os.remove(DOSSIER_MOD .. "actif.txt")
    local ok, err = package.loadlib(DOSSIER_MOD .. "ecran_capture.dll", "*")
    MODULE_CHARGE = ok and true or false
    journal("module " .. tostring(ok) .. " " .. tostring(err))
end

-- ---------------------------------------------------------------- screens

-- Searching the whole game for a class costs time: an object found is kept a few seconds.
-- Not for longer: after a map change the old one stays "valid" until Unreal collects it.
local DUREE_GARDE = 5
local GARDES = {}
local function objet_garde(classe)
    local t = os.clock()
    local g = GARDES[classe]
    if g and t < g.jusqua and g.objet:IsValid() then return g.objet end
    GARDES[classe] = nil
    for _, o in ipairs(FindAllOf(classe) or {}) do
        if o:IsValid() and not o:GetFullName():find("Default__", 1, true) then
            GARDES[classe] = { objet = o, jusqua = t + DUREE_GARDE }
            return o
        end
    end
    return nil
end

local function gestionnaire()
    return objet_garde("BP_LocationActivityManager_C")
end

local function assurer_instance(monde)
    if valide(INSTANCE) and valide(CIBLE) then return true end
    local rendu = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local materiaux = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    CIBLE = rendu:CreateRenderTarget2D(monde, LARGEUR, HAUTEUR, FORMAT_RGBA8_SRGB, { R = 0, G = 0, B = 0, A = 1 }, false, false)
    INSTANCE = materiaux:CreateDynamicMaterialInstance(monde, LoadAsset(MATERIAU), FName("None"), 0)
    INSTANCE:SetTextureParameterValue(FName(PARAM), CIBLE)
    journal("texture " .. nom(CIBLE))
    return valide(INSTANCE)
end

local FAMILLE_PAR_MAILLAGE = {}

local function famille_du_maillage(texte)
    for _, famille in ipairs(FAMILLES) do
        if contient(texte, famille.maillages) then return famille end
    end
    return nil
end

-- Keyed by full name, never by address: Unreal reuses the address of a destroyed component for the next one.
-- The game has about 960 of them and very few are screens. The mesh decides, and a mesh is only ever named once:
-- building the full name of every component is what used to freeze a frame.
local function balayer()
    local liste = FindAllOf("StaticMeshComponent")
    if not liste then return 0 end
    local nouveaux = 0
    for _, c in ipairs(liste) do
        local maillage = c.StaticMesh
        local famille = false
        if valide(maillage) then
            local adresse = maillage:GetAddress()
            famille = FAMILLE_PAR_MAILLAGE[adresse]
            if famille == nil then
                famille = famille_du_maillage(nom(maillage)) or false
                FAMILLE_PAR_MAILLAGE[adresse] = famille
            end
        end
        local cle = famille and c:GetFullName()
        if famille and not CONNUS[cle] then
            CONNUS[cle] = true
            local texte = nom(maillage)
            do
                for slot = 0, 3 do
                    local m = c:GetMaterial(slot)
                    if valide(m) then
                        local nom_materiau = m:GetFullName()
                        if contient(nom_materiau, famille.materiaux) then
                            ORIGINE_PAR_MAILLAGE[texte] = m
                            ECRANS[#ECRANS + 1] = { composant = c, slot = slot, origine = m, maillage = texte, famille = famille.id }
                            nouveaux = nouveaux + 1
                            break
                        elseif nom_materiau:find(MARQUE_NOTRE, 1, true) then
                            -- Spawned from a template that already got our picture: it must follow the menu too.
                            ECRANS[#ECRANS + 1] = { composant = c, slot = slot, origine = ORIGINE_PAR_MAILLAGE[texte], maillage = texte, famille = famille.id }
                            nouveaux = nouveaux + 1
                            break
                        end
                    end
                end
            end
        end
    end
    return nouveaux
end

local function tenir_ecrans()
    local debut = os.clock()
    local m = gestionnaire()
    if not m then
        regler_actif(false)
        return
    end
    local carte = m:GetFullName()
    if carte ~= CARTE then
        CARTE = carte
        ECRANS, CONNUS, FAMILLE_PAR_MAILLAGE = {}, {}, {}
        DERNIERE_ACTIVITE = nil
        FRAPPE.marche, FRAPPE.courant, FRAPPE.par_avatar = false, nil, {}
        journal("carte " .. carte)
    end
    -- Consoles appear with the activity: look right after a change, then rarely.
    if m.CurrentActivity ~= DERNIERE_ACTIVITE then
        DERNIERE_ACTIVITE = m.CurrentActivity
        TOUR = 0
    end
    if TOUR == 0 or TOUR == 1 or TOUR == 3 or TOUR == 6 or TOUR % TOURS_ENTRE_BALAYAGES == 0 then
        local debut_balayage = os.clock()
        local nouveaux = balayer()
        DUREE_BALAYAGE_MS = (os.clock() - debut_balayage) * 1000
        if nouveaux > 0 then
            journal(string.format("%d ecrans neufs, %d en tout, %.0f ms", nouveaux, #ECRANS, DUREE_BALAYAGE_MS))
        end
    end
    TOUR = TOUR + 1

    -- The screens of the place on screen show the picture. All the others, and "Off", get their original picture back.
    local lieu = lieu_de_activite(m.CurrentActivity)
    if lieu ~= LIEU_COURANT then
        LIEU_COURANT = lieu
        if lieu then
            appliquer_lieu()
            ecrire_config()
        end
        journal("endroit " .. (lieu and lieu.id or "aucun"))
    end
    local allume = lieu ~= nil and REGLAGES_LIEU[lieu.id].source ~= "aucune"
    local famille_allumee = allume and lieu.famille or nil
    if #ECRANS > 0 and (not allume or assurer_instance(m)) then
        local gardes = {}
        for _, e in ipairs(ECRANS) do
            if valide(e.composant) then
                gardes[#gardes + 1] = e
                -- Runs every second on every screen: the material's name is only read again when the material changed.
                local materiau = e.composant:GetMaterial(e.slot)
                local adresse = valide(materiau) and materiau:GetAddress() or 0
                if adresse ~= e.adresse_materiau then
                    e.adresse_materiau = adresse
                    e.nous = nom(materiau):find(MARQUE_NOTRE, 1, true) ~= nil
                end
                local nous = e.nous
                local voulu = e.famille == famille_allumee
                if voulu and not nous then
                    e.composant:SetMaterial(e.slot, INSTANCE)
                    e.adresse_materiau = nil
                elseif not voulu and nous then
                    e.adresse_materiau = nil
                    local origine = e.origine
                    if not valide(origine) then origine = ORIGINE_PAR_MAILLAGE[e.maillage] end
                    if not valide(origine) and e.famille == "consoles" then
                        origine = LoadAsset("/Game/VFX/Gifs/GoopiiMatchLoop/MI_GamingSreenStatic.MI_GamingSreenStatic")
                    end
                    if valide(origine) then
                        e.composant:SetMaterial(e.slot, origine)
                        MENU_DIAG.remis = MENU_DIAG.remis + 1
                    else
                        MENU_DIAG.sans_origine = MENU_DIAG.sans_origine + 1
                    end
                end
            end
        end
        ECRANS = gardes
    end
    regler_actif(allume)
    if gerer_mains then gerer_mains(m) end
    if FRAPPE.gerer then FRAPPE.gerer(m) end

    local duree = (os.clock() - debut) * 1000
    if duree > PIRE_TOUR_MS then PIRE_TOUR_MS = duree end
end

-- ---------------------------------------------------------------- test commands

local function commande_etat(sortie)
    local m = gestionnaire()
    sortie[#sortie + 1] = "module " .. tostring(MODULE_CHARGE) .. " pret " .. tostring(fichier_existe(DOSSIER_MOD .. "pret.txt"))
    sortie[#sortie + 1] = "actif " .. tostring(ACTIF) .. " activite " .. tostring(m and m.CurrentActivity) .. " lieu " .. tostring(m and m.CurrentLocation)
    sortie[#sortie + 1] = "ecrans " .. #ECRANS .. " texture " .. nom(CIBLE)
    sortie[#sortie + 1] = string.format("pire tour %.1f ms ; %d images vues en %.0f s", PIRE_TOUR_MS, TICKS, os.clock())
    PIRE_TOUR_MS = 0
end

-- Independent check: fresh look at every component, counts the screens still showing the game's fake picture.
local function commande_oublies(sortie)
    local liste = FindAllOf("StaticMeshComponent")
    local total, nos, oublies = 0, 0, 0
    for _, c in ipairs(liste or {}) do
        local famille = famille_du_maillage(nom(c.StaticMesh))
        if famille then
            for slot = 0, 3 do
                local m = c:GetMaterial(slot)
                if valide(m) then
                    local texte = m:GetFullName()
                    if texte:find(MARQUE_NOTRE, 1, true) then
                        nos = nos + 1
                    elseif contient(texte, famille.materiaux) and LIEU_COURANT and LIEU_COURANT.famille == famille.id then
                        oublies = oublies + 1
                    end
                end
            end
            total = total + 1
        end
    end
    sortie[#sortie + 1] = string.format("maillages %d ; ecrans a nous %d ; ecrans oublies %d ; suivis %d ; balayage %.0f ms",
        total, nos, oublies, #ECRANS, DUREE_BALAYAGE_MS)
    sortie[#sortie + 1] = string.format("remis %d ; sans origine %d", MENU_DIAG.remis, MENU_DIAG.sans_origine)
    for _, e in ipairs(ECRANS) do
        local texte = nom(e.composant:GetMaterial(e.slot))
        if texte:find(MARQUE_NOTRE, 1, true) then
            sortie[#sortie + 1] = "  reste " .. (nom(e.composant):match("([^%.]+%.[^%.]+)$") or "?") .. " origine " .. nom(e.origine)
            break
        end
    end
end

-- Negative control of the check above: puts the game's picture back on one screen on purpose.
local function commande_temoin(sortie)
    local e = ECRANS[1]
    if not e then sortie[#sortie + 1] = "pas d'ecran"; return end
    local materiau = LoadAsset("/Game/VFX/Gifs/GoopiiMatchLoop/MI_GamingSreenStatic.MI_GamingSreenStatic")
    e.composant:SetMaterial(e.slot, materiau)
    commande_oublies(sortie)
end

local function gestionnaire_cartes()
    for _, m in ipairs(FindAllOf("BP_MapManager_C") or {}) do
        if m:IsValid() and not m:GetFullName():find("Default__", 1, true) then return m end
    end
    return nil
end

local function commande_carte(sortie, nom_carte)
    local g = gestionnaire_cartes()
    if not g then sortie[#sortie + 1] = "pas de gestionnaire de cartes"; return end
    sortie[#sortie + 1] = "avant " .. g.CurrentMap:ToString()
    if nom_carte and nom_carte:match("^[%w_]+$") then
        g:SwitchMap(FName(nom_carte))
        sortie[#sortie + 1] = "demande " .. nom_carte
    end
    g.MapList:ForEach(function(cle)
        sortie[#sortie + 1] = "liste " .. cle:get():ToString()
    end)
end

local function avatar_bureau()
    return objet_garde("BP_AvatarOni_Desk_Gaming2_C")
end

local function texte_vecteur(v)
    return string.format("%.2f %.2f %.2f", v.X, v.Y, v.Z)
end

-- Read-only probe of what moves on the desk: skeleton, attachment of the mouse and the keyboard, hand positions.
local function commande_avatar(sortie)
    local a = avatar_bureau()
    if not a then sortie[#sortie + 1] = "pas d'avatar"; return end
    local corps = a.SkeletalMesh
    sortie[#sortie + 1] = "corps " .. nom(corps.SkeletalMeshAsset)
    sortie[#sortie + 1] = "mode animation " .. tostring(corps.AnimationMode) .. " classe " .. nom(corps.AnimClass)
    sortie[#sortie + 1] = "instance " .. nom(corps.AnimScriptInstance)
    sortie[#sortie + 1] = "acteur " .. texte_vecteur(a:K2_GetActorLocation())
    for _, champ in ipairs({ "SM_Mouse_Proxy", "SM_Computer_Keyboard", "SM_Computer_Monitor" }) do
        local c = a[champ]
        sortie[#sortie + 1] = champ .. " parent " .. nom(c:GetAttachParent()) .. " socket " .. c:GetAttachSocketName():ToString()
        sortie[#sortie + 1] = "  monde " .. texte_vecteur(c:K2_GetComponentLocation()) .. " relatif " .. texte_vecteur(c.RelativeLocation)
        sortie[#sortie + 1] = "  maillage " .. nom(c.StaticMesh) .. " visible " .. tostring(c:IsVisible())
    end
    for _, champ in ipairs({ "Hands", "Top", "Outfit", "Head", "Hair" }) do
        local c = a[champ]
        sortie[#sortie + 1] = champ .. " maillage " .. nom(c.SkeletalMeshAsset) .. " chef " .. nom(c.LeaderPoseComponent)
    end
    local total = corps:GetNumBones()
    sortie[#sortie + 1] = "os " .. tostring(total)
    for i = 0, total - 1 do
        local os_nom = corps:GetBoneName(i):ToString()
        if os_nom:lower():find("hand") or os_nom:lower():find("arm") or os_nom:lower():find("index") or os_nom:lower():find("clav")
            or os_nom:lower():find("thumb") or os_nom:lower():find("middle") or os_nom:lower():find("ring") or os_nom:lower():find("pinky") then
            local p = corps:GetSocketLocation(FName(os_nom))
            sortie[#sortie + 1] = "  " .. os_nom .. " " .. texte_vecteur(p)
        end
    end
end

-- ---------------------------------------------------------------- posable skeleton (hands follow the real ones)
-- The desk animation plays on the avatar's main skeleton. A PoseableMeshComponent copies it, then the arm bones are
-- bent by two-bone IK. The clothes and hands follow the poseable skeleton as their leader.

local ESPACE_MONDE = 0
local PARTIES = { "Hands", "Top", "Bottom", "Outfit", "Head", "Hair", "Ears", "Eyebrows", "FacialHair", "Glasses", "Hat", "Horns", "Shoes", "Socks" }
local POSE = { composant = nil, corps = nil, marche = false, pas = 0, cumul = 0, depart = 0, decalage_d = { X = 0, Y = 0, Z = 0 } }

local function v_moins(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
local function v_plus(a, b) return { X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z } end
local function v_fois(a, k) return { X = a.X * k, Y = a.Y * k, Z = a.Z * k } end
local function v_scal(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function v_long(a) return math.sqrt(v_scal(a, a)) end
local function v_croix(a, b)
    return { X = a.Y * b.Z - a.Z * b.Y, Y = a.Z * b.X - a.X * b.Z, Z = a.X * b.Y - a.Y * b.X }
end
local function v_unite(a)
    local l = v_long(a)
    if l < 0.0001 then return { X = 0, Y = 0, Z = 0 } end
    return v_fois(a, 1 / l)
end

local function q_fois(a, b)
    return {
        X = a.W * b.X + a.X * b.W + a.Y * b.Z - a.Z * b.Y,
        Y = a.W * b.Y - a.X * b.Z + a.Y * b.W + a.Z * b.X,
        Z = a.W * b.Z + a.X * b.Y - a.Y * b.X + a.Z * b.W,
        W = a.W * b.W - a.X * b.X - a.Y * b.Y - a.Z * b.Z,
    }
end

-- Shortest rotation taking direction a to direction b.
local function q_entre(a, b)
    local ua, ub = v_unite(a), v_unite(b)
    local c = v_croix(ua, ub)
    local w = 1 + v_scal(ua, ub)
    local l = math.sqrt(c.X * c.X + c.Y * c.Y + c.Z * c.Z + w * w)
    if l < 0.0001 then return { X = 0, Y = 0, Z = 0, W = 1 } end
    return { X = c.X / l, Y = c.Y / l, Z = c.Z / l, W = w / l }
end

local function lire_os(p, nom_os)
    local t = p:GetBoneTransformByName(FName(nom_os), ESPACE_MONDE)
    return {
        p = { X = t.Translation.X, Y = t.Translation.Y, Z = t.Translation.Z },
        q = { X = t.Rotation.X, Y = t.Rotation.Y, Z = t.Rotation.Z, W = t.Rotation.W },
        e = { X = t.Scale3D.X, Y = t.Scale3D.Y, Z = t.Scale3D.Z },
    }
end

local function ecrire_os(p, nom_os, position, rotation, echelle)
    p:SetBoneTransformByName(FName(nom_os), { Rotation = rotation, Translation = position, Scale3D = echelle }, ESPACE_MONDE)
end

-- Two-bone IK: puts the wrist on "cible" with the frozen hand orientation; "pole" fixes the side the elbow goes to,
-- so the elbow does not follow the animation either.
local function plier_bras(p, cote, cible, rotation_main, pole)
    local epaule = lire_os(p, "upperarm_" .. cote)
    local coude = lire_os(p, "forearm_" .. cote)
    local poignet = lire_os(p, "hand_" .. cote)
    local l1 = v_long(v_moins(coude.p, epaule.p))
    local l2 = v_long(v_moins(poignet.p, coude.p))
    local vers = v_moins(cible, epaule.p)
    local d = math.max(math.abs(l1 - l2) + 0.01, math.min(v_long(vers), l1 + l2 - 0.01))
    local u = v_unite(vers)
    local e0 = v_moins(coude.p, epaule.p)
    local v = v_unite(v_moins(pole, v_fois(u, v_scal(pole, u))))
    local a = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
    local h = math.sqrt(math.max(l1 * l1 - a * a, 0))
    local nouveau_coude = v_plus(epaule.p, v_plus(v_fois(u, a), v_fois(v, h)))
    local nouveau_poignet = v_plus(epaule.p, v_fois(u, d))
    ecrire_os(p, "upperarm_" .. cote, epaule.p, q_fois(q_entre(e0, v_moins(nouveau_coude, epaule.p)), epaule.q), epaule.e)
    ecrire_os(p, "forearm_" .. cote, nouveau_coude,
        q_fois(q_entre(v_moins(poignet.p, coude.p), v_moins(nouveau_poignet, nouveau_coude)), coude.q), coude.e)
    ecrire_os(p, "hand_" .. cote, nouveau_poignet, rotation_main, poignet.e)
    return nouveau_poignet
end

-- ---------------------------------------------------------------- real mouse and keyboard

local PIPE_Q, PIPE_R = "\\\\.\\pipe\\ecranreel_q", "\\\\.\\pipe\\ecranreel_r"
local ENTREES = { q = nil, r = nil, prochain_essai = 0, derniere = 0, questions = 0 }
local SIMULE = { dx = 0, dy = 0, boutons = 0, pressees = {}, bas = {} }

local function fermer_entrees()
    if ENTREES.q then pcall(function() ENTREES.q:close() end) end
    if ENTREES.r then pcall(function() ENTREES.r:close() end) end
    ENTREES.q, ENTREES.r = nil, nil
end

local function ouvrir_entrees(t)
    if ENTREES.q or t < ENTREES.prochain_essai then return end
    ENTREES.prochain_essai = t + 3
    local q = io.open(PIPE_Q, "wb")
    if not q then return end
    local r = io.open(PIPE_R, "rb")
    if not r then
        q:close()
        return
    end
    q:setvbuf("no")
    ENTREES.q, ENTREES.r = q, r
    journal("lecteur d'entrees relie")
end

-- Returns dx, dy, buttons, held keys (set), pressed keys (list). A dead helper gives a nil line, never a hang.
local function lire_entrees(t)
    local dx, dy, boutons, bas, pressees = SIMULE.dx, SIMULE.dy, SIMULE.boutons, {}, {}
    for code in pairs(SIMULE.bas) do bas[code] = true end
    for _, code in ipairs(SIMULE.pressees) do pressees[#pressees + 1] = code end
    SIMULE.dx, SIMULE.dy, SIMULE.pressees = 0, 0, {}
    ouvrir_entrees(t)
    if ENTREES.q then
        local ligne = nil
        local ok = pcall(function()
            ENTREES.q:write("?\n")
            ligne = ENTREES.r:read("*l")
        end)
        if not ok or not ligne then
            fermer_entrees()
            journal("lecteur d'entrees perdu")
        else
            ENTREES.questions = ENTREES.questions + 1
            local a, b, c, texte_bas, texte_pressees = ligne:match("^(-?%d+) (-?%d+) (%d+)|([%d,]*)|([%d,]*)")
            -- SIMULE.sourd: measuring stillness while someone is using the PC.
            if a and not SIMULE.sourd then
                dx, dy = dx + tonumber(a), dy + tonumber(b)
                boutons = boutons | tonumber(c)
                for code in texte_bas:gmatch("%d+") do bas[tonumber(code)] = true end
                for code in texte_pressees:gmatch("%d+") do pressees[#pressees + 1] = tonumber(code) end
            end
        end
    end
    return dx, dy, boutons, bas, pressees
end

-- ---------------------------------------------------------------- keyboard layout (physical keys, scan codes)
-- Column in key widths from the left edge of the main block (15 wide), row from the front (0) to the back (1).

local TOUCHES = {}
local function rangee(ligne, colonne, codes, largeur)
    for i, code in ipairs(codes) do
        TOUCHES[code] = { u = (colonne + (i - 1) * (largeur or 1)) / 15, v = ligne }
    end
end
rangee(1.0, 0.5, { 0x01 })
rangee(1.0, 2.5, { 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58 })
rangee(0.8, 0.5, { 0x29, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E })
rangee(0.6, 0.7, { 0x0F })
rangee(0.6, 2.0, { 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B })
rangee(0.5, 14.2, { 0x1C })
rangee(0.4, 0.8, { 0x3A })
rangee(0.4, 2.25, { 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2B })
rangee(0.2, 0.6, { 0x2A })
rangee(0.2, 1.75, { 0x56, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35 })
rangee(0.2, 13.5, { 0x36 })
rangee(0.0, 0.6, { 0x1D })
rangee(0.0, 2.0, { 0xE05B })
rangee(0.0, 3.2, { 0x38 })
rangee(0.0, 7.0, { 0x39 })
rangee(0.0, 10.5, { 0xE038 })
rangee(0.0, 14.0, { 0xE01D })

local TOUCHES_POUCE = { [0x39] = true, [0x38] = true, [0xE038] = true, [0xE05B] = true }
local CODE_ESPACE = 0x39

-- ---------------------------------------------------------------- hands copy the real ones
-- World axes at the desk: the avatar faces +Y, her left is +X.

local REGLAGES = {
    souris_cm_par_point = 1 / 350,  -- real mouse counts to cm on the desk
    souris_max_x = 9, souris_max_y = 6,
    -- The hand drifts back to the middle of the pad only while the mouse moves: a still mouse means a still hand.
    retour_par_cm = 0.06,
    duree_moyenne = 3,              -- seconds to find the resting place of each hand from the animation, then it is fixed
    lissage_souris = 0.045, relache_doigt = 0.09, attaque_doigt = 0.025,
    part_touches_largeur = 0.94, part_touches_profondeur = 0.8,  -- the keys inside the keyboard's edges
    courbure_repos = 0.5,           -- a hand on a keyboard is curved: fraction of a full press, kept in its shape
    gauche_max_u = 0.78,            -- the left hand stops reaching there, keys further right are "more or less"
    retour_gauche_s = 1.2,
    -- A real hand stays where it is and a finger reaches the key: it only travels for keys out of the fingers' range.
    lissage_gauche = 0.11, lissage_retour_gauche = 0.35,
    portee_doigt = 3.5,             -- cm: a key this close to a fingertip only moves the hand a little
    part_si_proche = 0.6,
    demi_barre_espace = 8,          -- cm each side of the space bar's middle
    garde_clavier = 0.7,            -- cm: the lowest fingertip rests this far above the top of the keyboard
    tourne_main = 0.6,             -- share of the forearm's turn that the hand follows
    angle_doigt_1 = math.rad(13), angle_doigt_2 = math.rad(11),
}

local MAINS = {
    t = nil, mx = 0, my = 0,
    centre_d = nil, centre_g = nil, cible_d = nil, cible_g = nil,
    ancre_g = nil, q_g = nil, derniere_touche = -100,
    doigts_bas = {},                -- held key -> finger pressing it
    appuis = { L = {}, R = {} },
}

local function q_axe(axe, angle)
    local s = math.sin(angle / 2)
    return { X = axe.X * s, Y = axe.Y * s, Z = axe.Z * s, W = math.cos(angle / 2) }
end

local function q_inverse(q)
    return { X = -q.X, Y = -q.Y, Z = -q.Z, W = q.W }
end

local function v_tourner(q, v)
    local u = { X = q.X, Y = q.Y, Z = q.Z }
    local t = v_fois(v_croix(u, v), 2)
    return v_plus(v_plus(v, v_fois(t, q.W)), v_croix(u, t))
end

local DOIGTS = { "thumb", "index", "middle", "ring", "pinky" }

-- Running average of rotations: the sum of quaternions on the same side, normalised.
local function q_ajouter(somme, q)
    local signe = (somme.X * q.X + somme.Y * q.Y + somme.Z * q.Z + somme.W * q.W) < 0 and -1 or 1
    somme.X, somme.Y, somme.Z, somme.W = somme.X + q.X * signe, somme.Y + q.Y * signe, somme.Z + q.Z * signe, somme.W + q.W * signe
    local l = math.sqrt(somme.X * somme.X + somme.Y * somme.Y + somme.Z * somme.Z + somme.W * somme.W)
    return { X = somme.X / l, Y = somme.Y / l, Z = somme.Z / l, W = somme.W / l }
end

-- The shape of a hand (fingers relative to the wrist) and where the elbow points. Built empty, then averaged over
-- the animation's first seconds: a single frame would catch the fingers in the middle of a keystroke.
local function figer_main(p, cote)
    local coude = lire_os(p, "forearm_" .. cote)
    local epaule = lire_os(p, "upperarm_" .. cote)
    local figee = { pole = v_moins(coude.p, epaule.p), os = {}, bouts = {}, n = 0, somme_q = { X = 0, Y = 0, Z = 0, W = 0 }, cote = cote }
    for _, doigt in ipairs(DOIGTS) do
        for _, segment in ipairs({ "_01_", "_02_", "_03_" }) do
            local o = { nom = doigt .. segment .. cote, somme_p = { X = 0, Y = 0, Z = 0 }, somme_q = { X = 0, Y = 0, Z = 0, W = 0 } }
            figee.os[#figee.os + 1] = o
            if segment == "_03_" then figee.bouts[doigt] = o end
        end
    end
    return figee
end

-- Reads the animation's pose: call right after copying it, before any bone is written.
local function moyenner_main(p, figee)
    local main = lire_os(p, "hand_" .. figee.cote)
    local inverse = q_inverse(main.q)
    figee.n = figee.n + 1
    figee.q = q_ajouter(figee.somme_q, main.q)
    for _, o in ipairs(figee.os) do
        local b = lire_os(p, o.nom)
        local rp = v_tourner(inverse, v_moins(b.p, main.p))
        o.somme_p = v_plus(o.somme_p, rp)
        o.p = v_fois(o.somme_p, 1 / figee.n)
        o.q = q_ajouter(o.somme_q, q_fois(inverse, b.q))
        o.e = b.e
    end
end

-- Puts the fingers back in their kept shape, parents first, on a wrist turned by "q".
local function poser_doigts(p, figee, poignet, q)
    for _, o in ipairs(figee.os) do
        ecrire_os(p, o.nom, v_plus(poignet, v_tourner(q, o.p)), q_fois(q, o.q), o.e)
    end
end

-- Chooses the finger for a key and how far the hand must travel for it.
local function viser_touche(code, touche)
    local r, k, figee = REGLAGES, POSE.clavier, MAINS.figee_g
    local poignet = MAINS.ancre_g or MAINS.cible_g
    local q = MAINS.q_g or figee.q
    local u = math.min(touche.u, r.gauche_max_u)
    local sur_largeur = (0.5 - u) * k.largeur
    local sur_profondeur = (touche.v - 0.5) * k.profondeur
    local touche_monde = {
        X = k.X + k.ax.X * sur_largeur + k.ay.X * sur_profondeur,
        Y = k.Y + k.ax.Y * sur_largeur + k.ay.Y * sur_profondeur,
    }
    -- A finger already holding a key stays on it, unless no other is free.
    local occupes = {}
    for autre, doigt in pairs(MAINS.doigts_bas) do
        if autre ~= code then occupes[doigt] = true end
    end
    if TOUCHES_POUCE[code] == nil and occupes.index and occupes.middle and occupes.ring and occupes.pinky then occupes = {} end
    local choix, meilleur = nil, math.huge
    for _, doigt in ipairs(DOIGTS) do
        if (doigt == "thumb") == (TOUCHES_POUCE[code] == true) and (doigt == "thumb" or not occupes[doigt]) then
            local bout = v_plus(poignet, v_tourner(q, figee.bouts[doigt].p))
            local cible = touche_monde
            if code == CODE_ESPACE then
                -- The space bar is long: the nearest point of the bar under the thumb.
                local long = (bout.X - touche_monde.X) * k.ax.X + (bout.Y - touche_monde.Y) * k.ax.Y
                long = math.max(-r.demi_barre_espace, math.min(r.demi_barre_espace, long))
                cible = { X = touche_monde.X + k.ax.X * long, Y = touche_monde.Y + k.ax.Y * long }
            end
            local ex, ey = cible.X - bout.X, cible.Y - bout.Y
            local distance = math.sqrt(ex * ex + ey * ey)
            if distance < meilleur then
                meilleur, choix = distance, { doigt = doigt, ex = ex, ey = ey, X = cible.X, Y = cible.Y }
            end
        end
    end
    local proche = meilleur < r.portee_doigt
    local part = proche and r.part_si_proche or 1
    MAINS.ancre_g = { X = poignet.X + choix.ex * part, Y = poignet.Y + choix.ey * part, Z = poignet.Z }
    MAINS.distance_touche = meilleur
    -- A far key: the hand turns as it travels, so the wrist's place is worked out again each step until the finger is on it.
    MAINS.visee = (not proche) and { X = choix.X, Y = choix.Y, doigt = choix.doigt } or nil
    MAINS.dernier_vise = { X = choix.X, Y = choix.Y, doigt = choix.doigt }
    return choix.doigt
end

-- Average of the animation's wrist over the first seconds, then fixed.
local function centre_moyen(cumul, valeur)
    cumul.n = cumul.n + 1
    cumul.X, cumul.Y, cumul.Z = cumul.X + valeur.X, cumul.Y + valeur.Y, cumul.Z + valeur.Z
    return { X = cumul.X / cumul.n, Y = cumul.Y / cumul.n, Z = cumul.Z / cumul.n }
end

local function vers_lisse(actuel, cible, dt, duree)
    local k = 1 - math.exp(-dt / duree)
    return { X = actuel.X + (cible.X - actuel.X) * k, Y = actuel.Y + (cible.Y - actuel.Y) * k, Z = actuel.Z + (cible.Z - actuel.Z) * k }
end

-- Bends a finger towards the desk by a fraction of the full press.
local function plier_doigt(p, cote, doigt, fraction)
    if fraction < 0.01 then return end
    if doigt == "thumb" then fraction = fraction * 0.6 end  -- the thumb is already low
    local suffixe = "_" .. cote
    local b1 = lire_os(p, doigt .. "_01" .. suffixe)
    local b2 = lire_os(p, doigt .. "_02" .. suffixe)
    local dir = v_unite(v_moins(b2.p, b1.p))
    local axe = v_unite(v_croix(dir, { X = 0, Y = 0, Z = -1 }))
    ecrire_os(p, doigt .. "_01" .. suffixe, b1.p, q_fois(q_axe(axe, fraction * REGLAGES.angle_doigt_1), b1.q), b1.e)
    b2 = lire_os(p, doigt .. "_02" .. suffixe)
    ecrire_os(p, doigt .. "_02" .. suffixe, b2.p, q_fois(q_axe(axe, fraction * REGLAGES.angle_doigt_2), b2.q), b2.e)
end

local function regler_appui(cote, doigt, bas, dt)
    local table_cote = MAINS.appuis[cote]
    local a = table_cote[doigt] or 0
    local duree = bas and REGLAGES.attaque_doigt or REGLAGES.relache_doigt
    local cible = bas and 1 or 0
    a = a + (cible - a) * (1 - math.exp(-dt / duree))
    table_cote[doigt] = a
end

local function pas_pose()
    local p, corps = POSE.composant, POSE.corps
    if not valide(p) or not valide(corps) then
        POSE.marche = false
        return
    end
    local debut = os.clock()
    local dt = MAINS.t and math.min(debut - MAINS.t, 0.1) or 0.016
    if dt <= 0 then dt = 0.001 end
    MAINS.t = debut

    p:CopyPoseFromSkeletalComponent(corps)
    local dx, dy, boutons, bas, pressees = lire_entrees(debut)

    -- Right hand: the mouse. Right on the real mouse is her right (-X); forwards (negative dy) is +Y.
    local maintenant_d = lire_os(p, "hand_R").p
    local maintenant_g = lire_os(p, "hand_L").p
    if not MAINS.centre_d then
        MAINS.centre_d, MAINS.cible_d = maintenant_d, maintenant_d
        MAINS.centre_g, MAINS.cible_g = maintenant_g, maintenant_g
        MAINS.cumul_d = { n = 0, X = 0, Y = 0, Z = 0 }
        MAINS.cumul_g = { n = 0, X = 0, Y = 0, Z = 0 }
        MAINS.figee_d, MAINS.figee_g = figer_main(p, "R"), figer_main(p, "L")
    end
    local r = REGLAGES
    -- The animation's own sway is averaged away once, then the resting place never changes.
    if debut - POSE.depart < r.duree_moyenne then
        MAINS.centre_d = centre_moyen(MAINS.cumul_d, maintenant_d)
        MAINS.centre_g = centre_moyen(MAINS.cumul_g, maintenant_g)
    end

    if debut - POSE.depart < r.duree_moyenne or not MAINS.figee_d.q then
        moyenner_main(p, MAINS.figee_d)
        moyenner_main(p, MAINS.figee_g)
    end

    local bouge_x, bouge_y = dx * r.souris_cm_par_point, dy * r.souris_cm_par_point
    MAINS.mx = math.max(-r.souris_max_x, math.min(r.souris_max_x, MAINS.mx + bouge_x))
    MAINS.my = math.max(-r.souris_max_y, math.min(r.souris_max_y, MAINS.my + bouge_y))
    local rappel = math.exp(-(math.abs(bouge_x) + math.abs(bouge_y)) * r.retour_par_cm)
    MAINS.mx, MAINS.my = MAINS.mx * rappel, MAINS.my * rappel
    local cible_d = { X = MAINS.centre_d.X - MAINS.mx, Y = MAINS.centre_d.Y - MAINS.my, Z = MAINS.centre_d.Z }
    MAINS.cible_d = vers_lisse(MAINS.cible_d, cible_d, dt, r.lissage_souris)
    local poignet_d = plier_bras(p, "R", MAINS.cible_d, MAINS.figee_d.q, MAINS.figee_d.pole)
    poser_doigts(p, MAINS.figee_d, poignet_d, MAINS.figee_d.q)

    -- Left hand: a finger takes each key, the hand only travels for keys out of its range.
    local repos_g = { X = MAINS.centre_g.X, Y = MAINS.centre_g.Y, Z = MAINS.z_repos_g or MAINS.centre_g.Z }
    if not MAINS.ancre_g and v_long(v_moins(MAINS.cible_g, repos_g)) < 0.01 then MAINS.cible_g = repos_g end
    if POSE.clavier then
        for _, code in ipairs(pressees) do
            local touche = TOUCHES[code]
            if touche then
                MAINS.doigts_bas[code] = viser_touche(code, touche)
                MAINS.derniere_touche = debut
            end
        end
    end
    local presses = {}
    for code, doigt in pairs(MAINS.doigts_bas) do
        if bas[code] then
            presses[doigt] = true
            MAINS.derniere_touche = debut
        else
            MAINS.doigts_bas[code] = nil
        end
    end
    if MAINS.ancre_g and debut - MAINS.derniere_touche >= r.retour_gauche_s then MAINS.ancre_g, MAINS.visee = nil, nil end
    if MAINS.ancre_g then
        MAINS.ancre_g.Z = repos_g.Z
        if MAINS.visee then
            local bout = v_tourner(MAINS.q_g or MAINS.figee_g.q, MAINS.figee_g.bouts[MAINS.visee.doigt].p)
            MAINS.ancre_g.X, MAINS.ancre_g.Y = MAINS.visee.X - bout.X, MAINS.visee.Y - bout.Y
        end
        MAINS.cible_g = vers_lisse(MAINS.cible_g, MAINS.ancre_g, dt, r.lissage_gauche)
    else
        MAINS.cible_g = vers_lisse(MAINS.cible_g, repos_g, dt, r.lissage_retour_gauche)
    end

    -- The hand turns with the forearm, about the vertical, so the wrist does not break when it travels.
    local epaule_g = lire_os(p, "upperarm_L").p
    local angle_repos = math.atan(repos_g.Y - epaule_g.Y, repos_g.X - epaule_g.X)
    local angle_main = math.atan(MAINS.cible_g.Y - epaule_g.Y, MAINS.cible_g.X - epaule_g.X)
    local tour = (angle_main - angle_repos) * r.tourne_main
    MAINS.q_g = q_fois(q_axe({ X = 0, Y = 0, Z = 1 }, tour), MAINS.figee_g.q)
    local poignet_g = plier_bras(p, "L", MAINS.cible_g, MAINS.q_g, MAINS.figee_g.pole)
    poser_doigts(p, MAINS.figee_g, poignet_g, MAINS.q_g)

    -- Once the shape is known, the curve of a hand on a keyboard goes into it, once and for all.
    if not MAINS.courbee and debut - POSE.depart >= r.duree_moyenne then
        MAINS.courbee = true
        for _, doigt in ipairs({ "index", "middle", "ring", "pinky" }) do
            plier_doigt(p, "L", doigt, r.courbure_repos)
        end
        local main = lire_os(p, "hand_L")
        local inverse = q_inverse(main.q)
        for _, o in ipairs(MAINS.figee_g.os) do
            local b = lire_os(p, o.nom)
            o.p, o.q = v_tourner(inverse, v_moins(b.p, main.p)), q_fois(inverse, b.q)
        end
        -- The hand's height comes from the keyboard: the lowest fingertip just above its top.
        if POSE.clavier then
            local plus_bas = math.huge
            for _, doigt in ipairs(DOIGTS) do
                plus_bas = math.min(plus_bas, v_tourner(main.q, MAINS.figee_g.bouts[doigt].p).Z)
            end
            MAINS.z_repos_g = POSE.clavier.Z + r.garde_clavier - plus_bas
        end
    end

    -- Fingers, after the arms: the mouse buttons on the right, the held keys on the left.
    regler_appui("R", "index", (boutons & 1) ~= 0, dt)
    regler_appui("R", "middle", (boutons & 2) ~= 0, dt)
    plier_doigt(p, "R", "index", MAINS.appuis.R.index or 0)
    plier_doigt(p, "R", "middle", MAINS.appuis.R.middle or 0)
    for _, doigt in ipairs(DOIGTS) do
        regler_appui("L", doigt, presses[doigt] or false, dt)
        plier_doigt(p, "L", doigt, MAINS.appuis.L[doigt] or 0)
    end

    POSE.pas = POSE.pas + 1
    POSE.cumul = POSE.cumul + (os.clock() - debut)
end

local function poser_squelette(sortie)
    local a = avatar_bureau()
    if not a then sortie[#sortie + 1] = "pas d'avatar"; return end
    local corps = a.SkeletalMesh
    local classe = StaticFindObject("/Script/Engine.PoseableMeshComponent")
    local p = a:AddComponentByClass(classe, true, {
        Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 },
    }, false)
    POSE.avatar = a
    POSE.branche = true
    sortie[#sortie + 1] = "composant " .. nom(p)
    local attache = p:K2_AttachToComponent(corps, FName("None"), 2, 2, 2, false)
    sortie[#sortie + 1] = "attache " .. tostring(attache)
    local actif = corps:GetSkinnedAsset()
    sortie[#sortie + 1] = "maillage du corps " .. nom(actif) .. " visible " .. tostring(corps:IsVisible())
    p:SetSkinnedAssetAndUpdate(actif, true)
    p.VisibilityBasedAnimTickOption = 0
    corps.VisibilityBasedAnimTickOption = 0
    for _, champ in ipairs(PARTIES) do
        local c = a[champ]
        if valide(c) and valide(c:GetSkinnedAsset()) then
            c:SetLeaderPoseComponent(p, true, false)
            sortie[#sortie + 1] = "partie " .. champ .. " " .. (nom(c:GetSkinnedAsset()):match("([^%.]+)$") or "?")
        end
    end
    -- The base body is an invisible mesh in the game: the poseable copy must stay invisible too.
    p:SetHiddenInGame(true, false)
    p:CopyPoseFromSkeletalComponent(corps)
    -- The mouse sits on the wrist, and only stays attached to a skeleton that refreshes its children.
    -- Keep its relative placement: the poseable socket is not at its final place yet, world placement would be wrong.
    local attache_souris = a.SM_Mouse_Proxy:K2_AttachToComponent(p, FName("hand_R"), 0, 0, 0, false)
    sortie[#sortie + 1] = "souris attachee " .. tostring(attache_souris)
    local k = a.SM_Computer_Keyboard
    local position, axe_x, axe_y = k:K2_GetComponentLocation(), k:GetForwardVector(), k:GetRightVector()
    -- The mesh's pivot is not its middle: the key area comes from its bounds, scaled like the component.
    local bornes = k.StaticMesh:GetBounds()
    local echelle = k.RelativeScale3D.X
    local ox, oy = bornes.Origin.X * echelle, bornes.Origin.Y * echelle
    POSE.clavier = {
        X = position.X + axe_x.X * ox + axe_y.X * oy,
        Y = position.Y + axe_x.Y * ox + axe_y.Y * oy,
        Z = position.Z + (bornes.Origin.Z + bornes.BoxExtent.Z) * echelle,
        ax = { X = axe_x.X, Y = axe_x.Y, Z = axe_x.Z },
        ay = { X = axe_y.X, Y = axe_y.Y, Z = axe_y.Z },
        largeur = 2 * bornes.BoxExtent.X * echelle * REGLAGES.part_touches_largeur,
        profondeur = 2 * bornes.BoxExtent.Y * echelle * REGLAGES.part_touches_profondeur,
    }
    sortie[#sortie + 1] = string.format("clavier milieu %.1f %.1f dessus %.1f ; %.1f x %.1f ; origine %.2f %.2f ; echelle %.2f",
        POSE.clavier.X, POSE.clavier.Y, POSE.clavier.Z, POSE.clavier.largeur, POSE.clavier.profondeur, bornes.Origin.X, bornes.Origin.Y, echelle)
    journal(sortie[#sortie])
    POSE.composant, POSE.corps = p, corps
    POSE.pas, POSE.cumul, POSE.depart = 0, 0, os.clock()
    MAINS.centre_d, MAINS.centre_g, MAINS.t = nil, nil, nil
    MAINS.ancre_g, MAINS.q_g, MAINS.doigts_bas, MAINS.courbee = nil, nil, {}, false
    MAINS.z_repos_g, MAINS.visee, MAINS.dernier_vise = nil, nil, nil
    POSE.marche = true
end

-- The poseable skeleton runs only while the desk is the avatar's place: nothing is computed otherwise.
gerer_mains = function(m)
    local activees = CONFIG.mains ~= "0"
    -- Switched off in the menu: the avatar goes back to the game's own animation.
    if not activees and POSE.branche and valide(POSE.avatar) and valide(POSE.composant) then
        POSE.marche = false
        POSE.branche = false
        local a = POSE.avatar
        for _, champ in ipairs(PARTIES) do
            local c = a[champ]
            if valide(c) and valide(c:GetSkinnedAsset()) then c:SetLeaderPoseComponent(a.SkeletalMesh, true, false) end
        end
        a.SM_Mouse_Proxy:K2_AttachToComponent(a.Hands, FName("hand_R"), 0, 0, 0, false)
        fermer_entrees()
        journal("mains rendues au jeu")
    end
    local a = avatar_bureau()
    local voulu = activees and a ~= nil and m.CurrentActivity == ACTIVITE_JOUER and not a.bHidden
    if not voulu then
        if POSE.marche then journal("mains en pause") end
        POSE.marche = false
        return
    end
    if POSE.marche then return end
    if valide(POSE.composant) then
        if not POSE.branche then
            for _, champ in ipairs(PARTIES) do
                local c = a[champ]
                if valide(c) and valide(c:GetSkinnedAsset()) then c:SetLeaderPoseComponent(POSE.composant, true, false) end
            end
            a.SM_Mouse_Proxy:K2_AttachToComponent(POSE.composant, FName("hand_R"), 0, 0, 0, false)
            POSE.branche = true
        end
        MAINS.t = nil
        POSE.marche = true
        journal("mains reprises")
        return
    end
    local sortie = {}
    poser_squelette(sortie)
    journal("mains posees : " .. tostring(POSE.marche))
end

-- ---------------------------------------------------------------- hands on the laptop (activity Typing)
-- Every Typing spot has its own avatar, sitting anywhere and any way round, with a laptop that may be tilted on its lap.
-- So nothing here uses world axes: left, right and forwards come from the laptop. Each real key lowers the finger a
-- touch typist would use, and the hand shifts towards that key from the place the game's animation gave it.
-- No key pressed: the hands rest. The mouse is not copied here, there is none on the laptop.

do
    local R_FRAPPE = {
        duree_moyenne = 3,          -- seconds to learn the resting hands from the animation
        part_clavier = 0.8,         -- share of the laptop's width taken by the keys
        pas_min = 1.4, pas_max = 2.6,  -- cm between two keys
        part_main = 0.7,            -- the rest of the way is the finger's
        aller = 0.05, retour = 0.3, -- smoothing of the wrist, seconds
        retour_apres = 0.7,         -- seconds without a key before the hand goes back to rest
        attaque = 0.02, relache = 0.08,
        appui_min = 0.07,           -- a very short tap still shows
    }
    local COTES = { "L", "R" }
    -- Finger, its resting key, and the keys it takes.
    local DISPOSITION = {
        { "L", "pinky", 0x1E, { 0x01, 0x29, 0x02, 0x0F, 0x10, 0x3A, 0x1E, 0x2A, 0x56, 0x2C, 0x1D, 0x3B } },
        { "L", "ring", 0x1F, { 0x03, 0x11, 0x1F, 0x2D, 0x3C } },
        { "L", "middle", 0x20, { 0x04, 0x12, 0x20, 0x2E, 0x3D, 0x3E } },
        { "L", "index", 0x21, { 0x05, 0x06, 0x13, 0x14, 0x21, 0x22, 0x2F, 0x30, 0x3F, 0x40 } },
        { "R", "index", 0x24, { 0x07, 0x08, 0x15, 0x16, 0x23, 0x24, 0x31, 0x32, 0x41, 0x42 } },
        { "R", "middle", 0x25, { 0x09, 0x17, 0x25, 0x33, 0x43 } },
        { "R", "ring", 0x26, { 0x0A, 0x18, 0x26, 0x34, 0x44 } },
        { "R", "pinky", 0x27, { 0x0B, 0x0C, 0x0D, 0x0E, 0x19, 0x1A, 0x1B, 0x1C, 0x27, 0x28, 0x2B, 0x35, 0x36, 0xE01D, 0x57, 0x58 } },
    }
    local TOUCHE_DOIGT = {}
    for _, ligne in ipairs(DISPOSITION) do
        local base = TOUCHES[ligne[3]]
        for _, code in ipairs(ligne[4]) do
            local t = TOUCHES[code]
            TOUCHE_DOIGT[code] = { cote = ligne[1], doigt = ligne[2], droite = (t.u - base.u) * 15, avant = (t.v - base.v) * 5 }
        end
    end
    for code, cote in pairs({ [0x39] = "R", [0xE038] = "R", [0x38] = "L", [0xE05B] = "L" }) do
        TOUCHE_DOIGT[code] = { cote = cote, doigt = "thumb", droite = 0, avant = 0 }
    end
    -- Arrows, numeric keypad and the like are not on a laptop's main block: the right index, without travelling.
    local HORS_BLOC = { cote = "R", doigt = "index", droite = 0, avant = 0 }

    local function avatar_visible(m)
        local trouve = nil
        m["Map Avatars to Activities"]:ForEach(function(cle)
            local a = cle:get()
            if not trouve and valide(a) and not a.bHidden then trouve = a end
        end)
        return trouve
    end

    local function portable_pres_de(main)
        local meilleur, distance = nil, 45
        for _, e in ipairs(ECRANS) do
            if e.famille == "portable" and valide(e.composant) and e.composant:IsVisible() then
                local d = v_long(v_moins(e.composant:K2_GetComponentLocation(), main))
                if d < distance and e.composant:K2_GetComponentScale().X > 0.01 then meilleur, distance = e.composant, d end
            end
        end
        return meilleur
    end

    local function copie(v) return { X = v.X, Y = v.Y, Z = v.Z } end

    -- The hands of this avatar follow the skeleton we pose, or the game's animation again.
    local function brancher(f, oui)
        local chef = oui and f.composant or f.corps
        for _, champ in ipairs(PARTIES) do
            local c = f.avatar[champ]
            if valide(c) and valide(c:GetSkinnedAsset()) then c:SetLeaderPoseComponent(chef, true, false) end
        end
        f.corps.VisibilityBasedAnimTickOption = oui and 0 or f.tick_origine
    end

    local function creer(a, portable)
        local corps = a.SkeletalMesh
        local p = a:AddComponentByClass(StaticFindObject("/Script/Engine.PoseableMeshComponent"), true, {
            Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 },
        }, false)
        p:K2_AttachToComponent(corps, FName("None"), 2, 2, 2, false)
        p:SetSkinnedAssetAndUpdate(corps:GetSkinnedAsset(), true)
        p.VisibilityBasedAnimTickOption = 0
        p:SetHiddenInGame(true, false)
        local avant, droite = copie(portable:GetForwardVector()), copie(portable:GetRightVector())
        -- Another laptop model could be built the other way round: the avatar's own body settles it.
        if v_scal(droite, v_moins(corps:GetSocketLocation(FName("upperarm_R")), corps:GetSocketLocation(FName("upperarm_L")))) < 0 then droite = v_fois(droite, -1) end
        if v_scal(avant, v_moins(corps:GetSocketLocation(FName("index_03_L")), corps:GetSocketLocation(FName("hand_L")))) < 0 then avant = v_fois(avant, -1) end
        local largeur = 2 * portable.StaticMesh:GetBounds().BoxExtent.Y * portable:K2_GetComponentScale().X
        return {
            avatar = a, corps = corps, composant = p, portable = portable, tick_origine = corps.VisibilityBasedAnimTickOption,
            avant = avant, droite = droite,
            pas_touche = math.max(R_FRAPPE.pas_min, math.min(R_FRAPPE.pas_max, largeur * R_FRAPPE.part_clavier / 15)),
            appris = 0, pas = 0, cumul = 0, tenues = {},
            mains = { L = { derniere = -100, fin_appui = {}, appuis = {} }, R = { derniere = -100, fin_appui = {}, appuis = {} } },
        }
    end

    FRAPPE.gerer = function(m)
        local activees = CONFIG.mains ~= "0"
        if not activees and ENTREES.q then fermer_entrees() end
        local voulu = activees and LIEU_PAR_ID.clavarder.activites[m.CurrentActivity] == true
        local f = FRAPPE.courant
        if f and (not voulu or not valide(f.avatar) or f.avatar.bHidden) then
            FRAPPE.marche, FRAPPE.courant = false, nil
            if valide(f.avatar) and valide(f.corps) then brancher(f, false) end
            journal("frappe en pause")
            f = nil
        end
        if not voulu or f then return end
        local a = avatar_visible(m)
        if not a then return end
        local cle = a:GetAddress()
        f = FRAPPE.par_avatar[cle]
        if not f then
            local portable = portable_pres_de(a.SkeletalMesh:GetSocketLocation(FName("hand_L")))
            if not portable then return end  -- the screens of this activity have not been seen yet
            f = creer(a, portable)
            FRAPPE.par_avatar[cle] = f
            journal(string.format("frappe posee, %.2f cm entre deux touches", f.pas_touche))
        else
            journal("frappe reprise")
        end
        brancher(f, true)
        f.t = nil
        lire_entrees(os.clock())  -- what was typed meanwhile is not for now
        FRAPPE.courant, FRAPPE.marche = f, true
    end

    FRAPPE.pas = function()
        local r, f = R_FRAPPE, FRAPPE.courant
        if not f or not valide(f.composant) or not valide(f.corps) then
            FRAPPE.marche = false
            return
        end
        local debut = os.clock()
        local dt = f.t and math.min(debut - f.t, 0.1) or 0.016
        if dt <= 0 then dt = 0.001 end
        f.t = debut
        local p = f.composant
        p:CopyPoseFromSkeletalComponent(f.corps)
        local _, _, _, bas, pressees = lire_entrees(debut)

        -- The resting place and shape of the hands, from the animation: read before any bone is written.
        local apprend = f.appris < r.duree_moyenne
        f.appris = f.appris + dt
        for _, cote in ipairs(COTES) do
            local h = f.mains[cote]
            local ici = lire_os(p, "hand_" .. cote).p
            if not h.centre then
                h.centre, h.cible = ici, ici
                h.cumul = { n = 0, X = 0, Y = 0, Z = 0 }
                h.figee = figer_main(p, cote)
            end
            if apprend then h.centre = centre_moyen(h.cumul, ici) end
            if apprend or not h.figee.q then moyenner_main(p, h.figee) end
        end

        for _, code in ipairs(pressees) do
            local d = TOUCHE_DOIGT[code] or HORS_BLOC
            local h = f.mains[d.cote]
            f.tenues[code] = d
            h.fin_appui[d.doigt] = debut + r.appui_min
            h.derniere, h.vers = debut, d
            f.derniere_touche = d
        end
        local tient = { L = {}, R = {} }
        for code, d in pairs(f.tenues) do
            if bas[code] then
                tient[d.cote][d.doigt] = true
                f.mains[d.cote].derniere = debut
            else
                f.tenues[code] = nil
            end
        end

        for _, cote in ipairs(COTES) do
            local h = f.mains[cote]
            local cible, duree = h.centre, r.retour
            if h.vers and debut - h.derniere < r.retour_apres then
                local part = f.pas_touche * r.part_main
                cible = v_plus(h.centre, v_plus(v_fois(f.droite, h.vers.droite * part), v_fois(f.avant, h.vers.avant * part)))
                duree = r.aller
            end
            h.cible = vers_lisse(h.cible, cible, dt, duree)
            local poignet = plier_bras(p, cote, h.cible, h.figee.q, h.figee.pole)
            poser_doigts(p, h.figee, poignet, h.figee.q)
            for _, doigt in ipairs(DOIGTS) do
                local en_bas = tient[cote][doigt] or (h.fin_appui[doigt] or 0) > debut
                local a = h.appuis[doigt] or 0
                a = a + ((en_bas and 1 or 0) - a) * (1 - math.exp(-dt / (en_bas and r.attaque or r.relache)))
                h.appuis[doigt] = a
                plier_doigt(p, cote, doigt, a)
            end
        end
        f.pas = f.pas + 1
        f.cumul = f.cumul + (os.clock() - debut)
    end

    -- Test probe: where everything is now.
    FRAPPE.commande = function(sortie)
        local f = FRAPPE.courant
        local connus, pilotes = 0, 0
        for _, autre in pairs(FRAPPE.par_avatar) do
            connus = connus + 1
            if valide(autre.avatar) and valide(autre.composant) then
                -- A weak pointer on the engine's side: read through Get when it has one.
                local brut = autre.avatar.Hands.LeaderPoseComponent
                local ok, chef = pcall(function() return brut:Get() end)
                if not ok or not chef then chef = brut end
                local ok2, adresse = pcall(function() return chef:GetAddress() end)
                if ok2 and adresse == autre.composant:GetAddress() then pilotes = pilotes + 1 end
            end
        end
        sortie[#sortie + 1] = "marche " .. tostring(FRAPPE.marche) .. " avatars " .. connus .. " pilotes " .. pilotes
        if not f or not valide(f.composant) then return end
        local p = f.composant
        sortie[#sortie + 1] = string.format("pas %d moyenne %.2f ms ; touche %.2f cm ; appris %.1f s", f.pas, f.cumul * 1000 / math.max(f.pas, 1), f.pas_touche, f.appris)
        local origine = f.portable:K2_GetComponentLocation()
        local haut = f.portable:GetUpVector()
        for _, cote in ipairs(COTES) do
            local h = f.mains[cote]
            sortie[#sortie + 1] = "main " .. cote .. " " .. texte_vecteur(lire_os(p, "hand_" .. cote).p)
            sortie[#sortie + 1] = "animation " .. cote .. " " .. texte_vecteur(f.corps:GetSocketLocation(FName("hand_" .. cote)))
            local plus_bas = math.huge
            local doigts = {}
            for _, doigt in ipairs(DOIGTS) do
                local b = lire_os(p, doigt .. "_03_" .. cote).p
                sortie[#sortie + 1] = "bout " .. cote .. " " .. doigt .. " " .. texte_vecteur(b)
                if doigt ~= "thumb" then plus_bas = math.min(plus_bas, v_scal(v_moins(b, origine), haut)) end
                doigts[#doigts + 1] = string.format("%s=%.2f", doigt, h.appuis[doigt] or 0)
            end
            sortie[#sortie + 1] = string.format("hauteur %s %.2f", cote, plus_bas)
            sortie[#sortie + 1] = "appuis " .. cote .. " " .. table.concat(doigts, " ")
        end
        local tenues = {}
        for code, d in pairs(f.tenues) do tenues[#tenues + 1] = string.format("%X=%s_%s", code, d.cote, d.doigt) end
        sortie[#sortie + 1] = "tenues " .. table.concat(tenues, " ")
    end
end

local function commande_pose(sortie)
    local duree = os.clock() - POSE.depart
    sortie[#sortie + 1] = string.format("marche %s ; pas %d en %.1f s (%.0f par s), moyenne %.2f ms ; questions %d", tostring(POSE.marche),
        POSE.pas, duree, POSE.pas / math.max(duree, 0.001), POSE.cumul * 1000 / math.max(POSE.pas, 1), ENTREES.questions)
    local p = POSE.composant
    if valide(p) then
        sortie[#sortie + 1] = "main droite " .. texte_vecteur(lire_os(p, "hand_R").p)
        sortie[#sortie + 1] = "main gauche " .. texte_vecteur(lire_os(p, "hand_L").p)
        sortie[#sortie + 1] = "index droit " .. texte_vecteur(lire_os(p, "index_03_R").p)
        sortie[#sortie + 1] = "index gauche " .. texte_vecteur(lire_os(p, "index_03_L").p)
        sortie[#sortie + 1] = "coude droit " .. texte_vecteur(lire_os(p, "forearm_R").p)
        sortie[#sortie + 1] = "animation main droite " .. texte_vecteur(POSE.corps:GetSocketLocation(FName("hand_R")))
        sortie[#sortie + 1] = "animation index gauche " .. texte_vecteur(POSE.corps:GetSocketLocation(FName("index_03_L")))
        sortie[#sortie + 1] = "centre droit " .. texte_vecteur(MAINS.centre_d or { X = 0, Y = 0, Z = 0 })
        sortie[#sortie + 1] = "souris modele " .. string.format("%.2f %.2f", MAINS.mx, MAINS.my)
        sortie[#sortie + 1] = string.format("age touche %.1f", os.clock() - MAINS.derniere_touche)
        local tenues = {}
        for code, doigt in pairs(MAINS.doigts_bas) do tenues[#tenues + 1] = string.format("%X=%s", code, doigt) end
        sortie[#sortie + 1] = "doigts " .. table.concat(tenues, " ") .. string.format(" ; distance %.1f", MAINS.distance_touche or -1)
        if POSE.clavier then
            local plus_bas = math.huge
            for _, doigt in ipairs(DOIGTS) do plus_bas = math.min(plus_bas, lire_os(p, doigt .. "_03_L").p.Z) end
            sortie[#sortie + 1] = string.format("hauteur doigt %.2f", plus_bas - POSE.clavier.Z)
        end
        if MAINS.dernier_vise then
            local b = lire_os(p, MAINS.dernier_vise.doigt .. "_03_L").p
            sortie[#sortie + 1] = string.format("erreur visee %.2f", math.sqrt((b.X - MAINS.dernier_vise.X) ^ 2 + (b.Y - MAINS.dernier_vise.Y) ^ 2))
        end
    end
    local a = avatar_bureau()
    if a then
        sortie[#sortie + 1] = "objet souris " .. texte_vecteur(a.SM_Mouse_Proxy:K2_GetComponentLocation())
        sortie[#sortie + 1] = "clavier " .. texte_vecteur(a.SM_Computer_Keyboard:K2_GetComponentLocation())
        local ok, bornes = pcall(function() return a.SM_Computer_Keyboard.StaticMesh:GetBounds() end)
        if ok and bornes then sortie[#sortie + 1] = "clavier etendue " .. texte_vecteur(bornes.BoxExtent) end
        sortie[#sortie + 1] = "clavier axe X " .. texte_vecteur(a.SM_Computer_Keyboard:GetForwardVector())
        sortie[#sortie + 1] = "clavier axe Y " .. texte_vecteur(a.SM_Computer_Keyboard:GetRightVector())
    end
end

-- Test feed, the same path as the real input: "souris_G", "souris_D", "souris_A", "souris_R", or a key's scan code in hex.
local function commande_simule(sortie, argument)
    local mouvements = { souris_G = { -1500, 0 }, souris_D = { 1500, 0 }, souris_A = { 0, -1000 }, souris_R = { 0, 1000 } }
    if mouvements[argument] then
        SIMULE.dx, SIMULE.dy = mouvements[argument][1], mouvements[argument][2]
    elseif argument == "sourd" then
        SIMULE.sourd = true
    elseif argument == "entend" then
        SIMULE.sourd = false
    elseif argument == "clic" then
        SIMULE.boutons = 1
    elseif argument == "relache" then
        SIMULE.boutons, SIMULE.bas = 0, {}
    elseif argument and argument:match("^%x+$") then
        local code = tonumber(argument, 16)
        SIMULE.bas[code] = true
        SIMULE.pressees[#SIMULE.pressees + 1] = code
    else
        sortie[#sortie + 1] = "argument refuse"
        return
    end
    sortie[#sortie + 1] = "ok " .. argument
end

-- Read-only probe of a widget tree: class and name of every widget, nested user widgets included.
local function arbre_widgets(w, profondeur, sortie, limite)
    if #sortie > limite or not valide(w) then return end
    local classe = w:GetClass():GetFName():ToString()
    local visible = ""
    local okv, v = pcall(function() return w:IsVisible() end)
    if okv and v == false then visible = " (cache)" end
    sortie[#sortie + 1] = string.rep(" ", profondeur) .. classe .. " " .. w:GetFName():ToString() .. visible
    if profondeur > 12 then return end
    local ok, n = pcall(function() return w:GetChildrenCount() end)
    if ok and type(n) == "number" then
        for i = 0, n - 1 do arbre_widgets(w:GetChildAt(i), profondeur + 1, sortie, limite) end
    end
    local okc, contenu = pcall(function() return w:GetContent() end)
    if okc and valide(contenu) then arbre_widgets(contenu, profondeur + 1, sortie, limite) end
    if classe:sub(-2) == "_C" then
        local arbre = w.WidgetTree
        if valide(arbre) then
            local racine = arbre.RootWidget
            if valide(racine) then arbre_widgets(racine, profondeur + 1, sortie, limite) end
        end
    end
end

local function commande_panneau(sortie, classe)
    local nom_classe = (classe and classe ~= "") and classe or "UI_SettingsPanel_C"
    local liste = FindAllOf(nom_classe)
    sortie[#sortie + 1] = nom_classe .. " instances " .. tostring(liste and #liste or 0)
    for _, w in ipairs(liste or {}) do
        if not w:GetFullName():find("Default__", 1, true) then
            sortie[#sortie + 1] = "dans l'ecran " .. tostring(w:IsInViewport()) .. " " .. nom(w)
            local ok, err = pcall(arbre_widgets, w, 0, sortie, 1500)
            if not ok then sortie[#sortie + 1] = "ERREUR arbre " .. tostring(err) end
            break
        end
    end
end

local function hud()
    return objet_garde("UI_BedroomHUD_C")
end

-- Opens the game's options and walks the tree from the widgets the blueprint names.
local function commande_options(sortie)
    local h = hud()
    if not h then sortie[#sortie + 1] = "pas de HUD"; return end
    h:EvSimulateSettingsPress()
    local p = h.UI_SettingsPanel
    sortie[#sortie + 1] = "panneau " .. nom(p) .. " visible " .. tostring(p:IsVisible())
    sortie[#sortie + 1] = "onglet " .. tostring(p.WidgetSwitcher:GetActiveWidgetIndex())
    arbre_widgets(p.WidgetSwitcher, 0, sortie, 1200)
    sortie[#sortie + 1] = "=== bouton FAQ"
    arbre_widgets(p.WBP_BaseButton_OpenFAQ, 0, sortie, 1300)
    local parent = p.WBP_BaseButton_OpenFAQ:GetParent()
    sortie[#sortie + 1] = "parent du bouton FAQ " .. nom(parent)
    local n = parent:GetChildrenCount()
    sortie[#sortie + 1] = "enfants " .. tostring(n)
    sortie[#sortie + 1] = "=== canvas"
    sortie[#sortie + 1] = nom(h.HUDCanvas) .. " enfants " .. tostring(h.HUDCanvas:GetChildrenCount())
end

-- ---------------------------------------------------------------- the menu, inside the game's own options
-- Built from the game's own widgets (setting row, dropdown), so it has their look and follows the player's theme.
-- Nothing can be bound to a button from Lua: the dropdowns' selection is read while the options are open.

-- One table per language of the game. %s in source_d is the game's own name for the activity.
local TEXTES = {
    en = {
        section = "REAL SCREEN",
        lieu_t = "Place", lieu_d = "Pick a place in the game that has a screen. The settings below apply to it, and each place keeps its own.",
        source_t = "Show on the in-game screen", source_d = "Only visible during the \"%s\" activity: start it to see the picture",
        ecran = "Screen %s (%s)", application = "An application", video = "A video", aucune = "Off",
        app_t = "Application", app_d = "The window to show, among those open",
        vid_t = "Video", vid_d = "The file to play on a loop", parcourir = "Browse…", aucun_fichier = "No file",
        son_t = "Video sound", son_d = "Hear the video along with the music",
        mains_t = "The avatar copies my mouse and keyboard",
        mains_d = "Reads your keys and mouse while the game is open, without saving anything. Turn it off before playing a game with anti-cheat.",
        oui = "Yes", non = "No",
        absente = "Window not found: open it or pick another one", video_absente = "File not found", video_refusee = "Windows cannot play this file",
    },
    fr = {
        section = "ÉCRAN RÉEL",
        lieu_t = "Endroit", lieu_d = "Choisissez un endroit du jeu où il y a un écran. Les réglages ci-dessous s'appliquent à lui, et chaque endroit garde les siens.",
        source_t = "Afficher sur l'écran du jeu", source_d = "Visible seulement pendant l'activité « %s » : lancez-la pour voir l'image",
        ecran = "Écran %s (%s)", application = "Une application", video = "Une vidéo", aucune = "Désactivé",
        app_t = "Application", app_d = "La fenêtre à afficher, parmi celles ouvertes",
        vid_t = "Vidéo", vid_d = "Le fichier à lire en boucle", parcourir = "Parcourir…", aucun_fichier = "Aucun fichier",
        son_t = "Son de la vidéo", son_d = "Entendre la vidéo en même temps que la musique",
        mains_t = "L'avatar copie ma souris et mon clavier",
        mains_d = "Lit vos touches et votre souris tant que le jeu est ouvert, sans rien enregistrer. Coupez-le avant un jeu avec anti-triche.",
        oui = "Oui", non = "Non",
        absente = "Fenêtre introuvable : ouvrez-la ou choisissez-en une autre", video_absente = "Fichier introuvable", video_refusee = "Windows ne sait pas lire ce fichier",
    },
    it = {
        section = "SCHERMO REALE",
        lieu_t = "Luogo", lieu_d = "Scegli un punto del gioco con uno schermo. Le impostazioni qui sotto valgono per quello, e ogni luogo ha le sue.",
        source_t = "Mostra sullo schermo del gioco", source_d = "Visibile solo durante l'attività «%s»: avviala per vedere l'immagine",
        ecran = "Schermo %s (%s)", application = "Un'applicazione", video = "Un video", aucune = "Disattivato",
        app_t = "Applicazione", app_d = "La finestra da mostrare, tra quelle aperte",
        vid_t = "Video", vid_d = "Il file da riprodurre in loop", parcourir = "Sfoglia…", aucun_fichier = "Nessun file",
        son_t = "Audio del video", son_d = "Ascolta il video insieme alla musica",
        mains_t = "L'avatar copia il mio mouse e la mia tastiera",
        mains_d = "Legge tasti e mouse mentre il gioco è aperto, senza salvare nulla. Disattivalo prima di un gioco con anti-cheat.",
        oui = "Sì", non = "No",
        absente = "Finestra non trovata: aprila o scegline un'altra", video_absente = "File non trovato", video_refusee = "Windows non riesce a riprodurre questo file",
    },
    de = {
        section = "ECHTER BILDSCHIRM",
        lieu_t = "Ort", lieu_d = "Wähle eine Stelle im Spiel mit einem Bildschirm. Die Einstellungen unten gelten dafür, und jeder Ort behält seine eigenen.",
        source_t = "Auf dem Bildschirm im Spiel anzeigen", source_d = "Nur während der Aktivität „%s“ sichtbar: Starte sie, um das Bild zu sehen",
        ecran = "Bildschirm %s (%s)", application = "Eine Anwendung", video = "Ein Video", aucune = "Aus",
        app_t = "Anwendung", app_d = "Das anzuzeigende Fenster, unter den geöffneten",
        vid_t = "Video", vid_d = "Die Datei, die in Schleife abgespielt wird", parcourir = "Durchsuchen…", aucun_fichier = "Keine Datei",
        son_t = "Ton des Videos", son_d = "Das Video zusammen mit der Musik hören",
        mains_t = "Der Avatar übernimmt meine Maus und Tastatur",
        mains_d = "Liest Tasten und Maus, solange das Spiel offen ist, ohne etwas zu speichern. Vor Spielen mit Anti-Cheat ausschalten.",
        oui = "Ja", non = "Nein",
        absente = "Fenster nicht gefunden: Öffne es oder wähle ein anderes", video_absente = "Datei nicht gefunden", video_refusee = "Windows kann diese Datei nicht abspielen",
    },
    es = {
        section = "PANTALLA REAL",
        lieu_t = "Lugar", lieu_d = "Elige un lugar del juego con pantalla. Los ajustes de abajo se aplican a él, y cada lugar guarda los suyos.",
        source_t = "Mostrar en la pantalla del juego", source_d = "Solo visible durante la actividad «%s»: iníciala para ver la imagen",
        ecran = "Pantalla %s (%s)", application = "Una aplicación", video = "Un vídeo", aucune = "Desactivado",
        app_t = "Aplicación", app_d = "La ventana que se muestra, entre las abiertas",
        vid_t = "Vídeo", vid_d = "El archivo que se reproduce en bucle", parcourir = "Examinar…", aucun_fichier = "Ningún archivo",
        son_t = "Sonido del vídeo", son_d = "Oír el vídeo junto con la música",
        mains_t = "El avatar copia mi ratón y mi teclado",
        mains_d = "Lee tus teclas y tu ratón mientras el juego está abierto, sin guardar nada. Desactívalo antes de un juego con antitrampas.",
        oui = "Sí", non = "No",
        absente = "Ventana no encontrada: ábrela o elige otra", video_absente = "Archivo no encontrado", video_refusee = "Windows no puede reproducir este archivo",
    },
    pt = {
        section = "TELA REAL",
        lieu_t = "Local", lieu_d = "Escolha um local do jogo com tela. As configurações abaixo valem para ele, e cada local guarda as suas.",
        source_t = "Mostrar na tela do jogo", source_d = "Visível apenas durante a atividade “%s”: inicie-a para ver a imagem",
        ecran = "Tela %s (%s)", application = "Um aplicativo", video = "Um vídeo", aucune = "Desativado",
        app_t = "Aplicativo", app_d = "A janela a mostrar, entre as abertas",
        vid_t = "Vídeo", vid_d = "O arquivo a reproduzir em loop", parcourir = "Procurar…", aucun_fichier = "Nenhum arquivo",
        son_t = "Som do vídeo", son_d = "Ouvir o vídeo junto com a música",
        mains_t = "O avatar copia meu mouse e meu teclado",
        mains_d = "Lê suas teclas e seu mouse enquanto o jogo está aberto, sem salvar nada. Desative antes de um jogo com antitrapaça.",
        oui = "Sim", non = "Não",
        absente = "Janela não encontrada: abra-a ou escolha outra", video_absente = "Arquivo não encontrado", video_refusee = "O Windows não consegue reproduzir este arquivo",
    },
    ja = {
        section = "リアルスクリーン",
        lieu_t = "場所", lieu_d = "画面がある場所を選びます。下の設定はその場所に適用され、場所ごとに保存されます。",
        source_t = "ゲーム内の画面に表示", source_d = "「%s」アクティビティ中のみ表示されます。開始すると映像が見られます",
        ecran = "画面 %s (%s)", application = "アプリケーション", video = "動画", aucune = "オフ",
        app_t = "アプリケーション", app_d = "開いているウィンドウから表示するものを選びます",
        vid_t = "動画", vid_d = "ループ再生するファイル", parcourir = "参照…", aucun_fichier = "ファイルなし",
        son_t = "動画の音声", son_d = "音楽と一緒に動画の音声を聞きます",
        mains_t = "アバターがマウスとキーボードの動きをまねする",
        mains_d = "ゲームの起動中、キーとマウスの操作を読み取ります（保存はしません）。アンチチートのあるゲームの前にオフにしてください。",
        oui = "はい", non = "いいえ",
        absente = "ウィンドウが見つかりません。開くか、別のものを選んでください", video_absente = "ファイルが見つかりません", video_refusee = "Windows ではこのファイルを再生できません",
    },
    zh = {
        section = "真实屏幕",
        lieu_t = "位置", lieu_d = "选择游戏中有屏幕的位置。下面的设置只对它生效,每个位置各自保存。",
        source_t = "在游戏屏幕上显示", source_d = "仅在“%s”活动期间可见：开始该活动即可看到画面",
        ecran = "屏幕 %s (%s)", application = "应用程序", video = "视频", aucune = "关闭",
        app_t = "应用程序", app_d = "从已打开的窗口中选择要显示的窗口",
        vid_t = "视频", vid_d = "循环播放的文件", parcourir = "浏览…", aucun_fichier = "没有文件",
        son_t = "视频声音", son_d = "在听音乐的同时听到视频声音",
        mains_t = "角色模仿我的鼠标和键盘",
        mains_d = "游戏打开时读取你的按键和鼠标，不保存任何内容。运行带反作弊的游戏前请关闭。",
        oui = "是", non = "否",
        absente = "找不到窗口：请打开它或选择其他窗口", video_absente = "找不到文件", video_refusee = "Windows 无法播放此文件",
    },
    ko = {
        section = "리얼 스크린",
        lieu_t = "위치", lieu_d = "게임에서 화면이 있는 위치를 선택하세요. 아래 설정은 그 위치에 적용되며 위치마다 따로 저장됩니다.",
        source_t = "게임 화면에 표시", source_d = "'%s' 활동 중에만 표시됩니다. 활동을 시작하면 화면을 볼 수 있습니다",
        ecran = "화면 %s (%s)", application = "응용 프로그램", video = "동영상", aucune = "끄기",
        app_t = "응용 프로그램", app_d = "열려 있는 창 중에서 표시할 창",
        vid_t = "동영상", vid_d = "반복 재생할 파일", parcourir = "찾아보기…", aucun_fichier = "파일 없음",
        son_t = "동영상 소리", son_d = "음악과 함께 동영상 소리를 듣습니다",
        mains_t = "아바타가 내 마우스와 키보드를 따라 합니다",
        mains_d = "게임이 열려 있는 동안 키와 마우스 입력을 읽으며 아무것도 저장하지 않습니다. 안티치트가 있는 게임 전에는 끄세요.",
        oui = "예", non = "아니요",
        absente = "창을 찾을 수 없습니다. 창을 열거나 다른 창을 선택하세요", video_absente = "파일을 찾을 수 없습니다", video_refusee = "Windows에서 이 파일을 재생할 수 없습니다",
    },
    ru = {
        section = "НАСТОЯЩИЙ ЭКРАН",
        lieu_t = "Место", lieu_d = "Выберите место в игре, где есть экран. Настройки ниже относятся к нему, у каждого места свои.",
        source_t = "Показывать на экране в игре", source_d = "Видно только во время занятия «%s»: начните его, чтобы увидеть изображение",
        ecran = "Экран %s (%s)", application = "Приложение", video = "Видео", aucune = "Выключено",
        app_t = "Приложение", app_d = "Окно для показа, из открытых",
        vid_t = "Видео", vid_d = "Файл для воспроизведения по кругу", parcourir = "Обзор…", aucun_fichier = "Нет файла",
        son_t = "Звук видео", son_d = "Слышать видео вместе с музыкой",
        mains_t = "Аватар повторяет мою мышь и клавиатуру",
        mains_d = "Считывает клавиши и мышь, пока игра открыта, ничего не сохраняя. Отключите перед игрой с античитом.",
        oui = "Да", non = "Нет",
        absente = "Окно не найдено: откройте его или выберите другое", video_absente = "Файл не найден", video_refusee = "Windows не может воспроизвести этот файл",
    },
}

local DELAI_AVANT_PREMIER_CHOIX = 1.5
local MENU = { lieu_choisi = "jouer", cree_a = 0, cree = false, lignes = {}, fenetres = {}, ecrans = {}, liste_demandee = 0, visible = false, panneau = nil, prochain_hud = 0, texte = TEXTES.en, etat = "", langue = nil }

local function langue_du_jeu()
    local ok, langue = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary"):GetCurrentLanguage():ToString()
    end)
    return (ok and langue) or "en"
end

local function choisir_langue()
    MENU.langue = langue_du_jeu()
    -- pt-BR gives pt, zh-Hans gives zh. A language the game may add later falls back on English.
    MENU.texte = TEXTES[MENU.langue:sub(1, 2):lower()] or TEXTES.en
end

-- The game's own name for the Gaming activity, in the current language, from its activity table.
-- The field names carry a build-specific suffix: if an update changes them, the table above takes over.
-- The name the game itself gives this activity, in its language.
local function nom_lieu(lieu)
    local ok, v = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetTextLibrary"):TextFromStringTable(FName(TABLE_TEXTES_JEU), lieu.cle_nom):ToString()
    end)
    if ok and v and v ~= "" and not v:find("<MISSING", 1, true) then return v end
    return lieu.noms[(MENU.langue or "en"):sub(1, 2):lower()] or lieu.noms.en
end

local function nom_jouer()
    return nom_lieu(LIEU_PAR_ID.jouer)
end

local function nouveau_widget(classe_moteur, outer)
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. classe_moteur), outer)
end

local function copier_case(de, vers)
    vers:SetPadding(de.Padding)
    vers:SetSize(de.Size)
    vers:SetHorizontalAlignment(de.HorizontalAlignment)
    vers:SetVerticalAlignment(de.VerticalAlignment)
end

local function regler_textes(ligne, titre, description)
    ligne.item.Title = FText(titre)
    ligne.item.Description = FText(description)
    ligne.item:Update()
    ligne.description = description
end

-- One row built like the game's own: SizeBox > Border > HorizontalBox > (texts, spacer, dropdown).
local function creer_ligne(p, modele, boite)
    local bib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local joueur = p:GetOwningPlayer()
    local sb = nouveau_widget("SizeBox", p)
    sb:SetHeightOverride(modele.taille.HeightOverride)
    local bord = nouveau_widget("Border", p)
    bord:SetBrush(modele.bord.Background)
    bord:SetPadding(modele.bord.Padding)
    bord:SetBrushColor(modele.bord.BrushColor)
    local rang = nouveau_widget("HorizontalBox", p)
    local item = bib:Create(p, modele.classe_item, joueur)
    local espace = nouveau_widget("Spacer", p)
    local liste = bib:Create(p, modele.classe_liste, joueur)
    sb:SetContent(bord)
    bord:SetContent(rang)
    copier_case(modele.item.Slot, rang:AddChild(item))
    copier_case(modele.espace.Slot, rang:AddChild(espace))
    copier_case(modele.liste.Slot, rang:AddChild(liste))
    copier_case(modele.taille.Slot, boite:AddChild(sb))
    return { boite = sb, item = item, liste = liste, options = {}, valeur = nil }
end

local function creer_menu(p)
    choisir_langue()
    local t = MENU.texte
    local modele_liste = p.WB_TimeFormatSelector
    local rang = modele_liste:GetParent()
    local bord = rang:GetParent()
    local taille = bord:GetParent()
    local boite = taille:GetParent()
    local modele = {
        taille = taille, bord = bord, liste = modele_liste,
        item = rang:GetChildAt(0), espace = rang:GetChildAt(1),
        classe_item = rang:GetChildAt(0):GetClass(), classe_liste = modele_liste:GetClass(),
    }
    -- The section title, like the game's first one.
    local titre_modele = boite:GetChildAt(0)
    local titre = nouveau_widget("TextBlock", p)
    titre:SetFont(titre_modele.Font)
    titre:SetColorAndOpacity(titre_modele.ColorAndOpacity)
    titre:SetText(FText(t.section))
    MENU.titre = titre

    -- The section sits in its own box in the same overlay, and pushes the game's list down by its height.
    -- The game's rows are never taken out: rebuilding them shrinks their text (15 to 11.25) and runs their setup again.
    local section = nouveau_widget("VerticalBox", p)
    copier_case(titre_modele.Slot, section:AddChild(titre))
    local superposition = boite:GetParent()
    local case_section = superposition:AddChild(section)
    case_section:SetHorizontalAlignment(0)  -- fill
    case_section:SetVerticalAlignment(1)    -- top
    local pad = boite.Slot.Padding
    MENU.boite_jeu = boite
    MENU.section = section
    MENU.marge_jeu = { Left = pad.Left, Top = pad.Top, Right = pad.Right, Bottom = pad.Bottom }
    MENU.decalage = -1

    local l = MENU.lignes
    l.lieu = creer_ligne(p, modele, section)
    l.source = creer_ligne(p, modele, section)
    l.app = creer_ligne(p, modele, section)
    l.video = creer_ligne(p, modele, section)
    l.son = creer_ligne(p, modele, section)
    l.mains = creer_ligne(p, modele, section)
    regler_textes(l.lieu, t.lieu_t, t.lieu_d)
    regler_textes(l.source, t.source_t, string.format(t.source_d, nom_lieu(LIEU_PAR_ID[MENU.lieu_choisi])))
    MENU.lieu_affiche = MENU.lieu_choisi
    regler_textes(l.app, t.app_t, t.app_d)
    regler_textes(l.video, t.vid_t, t.vid_d)
    regler_textes(l.son, t.son_t, t.son_d)
    regler_textes(l.mains, t.mains_t, t.mains_d)

    MENU.cree = true
    MENU.cree_a = os.clock()
    journal("menu cree")
end

-- Fills a dropdown when its options changed, or when the game's own code emptied it.
local function regler_options(ligne, options, selection)
    local combo = ligne.liste.ComboBox
    local identiques = #options == #ligne.options and combo:GetOptionCount() == #options
    if identiques then
        for i, o in ipairs(options) do
            if ligne.options[i] ~= o then identiques = false end
        end
    end
    if not identiques then
        combo:ClearOptions()
        for _, o in ipairs(options) do combo:AddOption(o) end
        ligne.options = options
    end
    if not identiques or ligne.valeur ~= selection then
        combo:SetSelectedOption(selection)
        ligne.valeur = selection
    end
end

local function lire_liste()
    local f = io.open(DOSSIER_MOD .. "fenetres.txt", "r")
    if not f then return end
    local ecrans, fenetres = {}, {}
    for ligne in f:lines() do
        local genre, a, b = ligne:match("^(%a)\t([^\t]*)\t(.*)$")
        if genre == "E" then
            ecrans[#ecrans + 1] = { numero = a, taille = b }
        elseif genre == "F" then
            fenetres[#fenetres + 1] = { exe = a, titre = b }
        end
    end
    f:close()
    if #ecrans > 0 then MENU.ecrans = ecrans end
    MENU.fenetres = fenetres
end

local function nom_fichier(chemin)
    return chemin:match("([^/\\]+)$") or chemin
end

local function court(texte)
    if #texte <= 46 then return texte end
    local fin = utf8.offset(texte, 45) or 46
    return texte:sub(1, fin - 1) .. "…"
end

-- What each dropdown offers right now, and what each choice does.
local function construire_choix()
    local t = MENU.texte
    local R = REGLAGES_LIEU[MENU.lieu_choisi]
    local lieux, actions_lieu = {}, {}
    local lieu_choisi = nil
    for _, lieu in ipairs(LIEUX) do
        local texte = nom_lieu(lieu)
        lieux[#lieux + 1] = texte
        actions_lieu[texte] = lieu.id
        if lieu.id == MENU.lieu_choisi then lieu_choisi = texte end
    end
    local source, actions_source = {}, {}
    local ecrans = #MENU.ecrans > 0 and MENU.ecrans or { { numero = R.numero, taille = "?" } }
    table.sort(ecrans, function(a, b) return (tonumber(a.numero) or 0) < (tonumber(b.numero) or 0) end)
    local choisi = nil
    for _, e in ipairs(ecrans) do
        local texte = string.format(t.ecran, e.numero, e.taille)
        source[#source + 1] = texte
        actions_source[texte] = { source = "ecran", numero = e.numero }
        if R.source == "ecran" and R.numero == e.numero then choisi = texte end
    end
    -- The chosen monitor is switched off for now: it stays chosen, and the row must not pretend another one is.
    if R.source == "ecran" and not choisi then
        choisi = string.format(t.ecran, R.numero, "?")
        table.insert(source, 1, choisi)
        actions_source[choisi] = { source = "ecran", numero = R.numero }
    end
    source[#source + 1] = t.application
    actions_source[t.application] = { source = "fenetre" }
    source[#source + 1] = t.video
    actions_source[t.video] = { source = "video" }
    source[#source + 1] = t.aucune
    actions_source[t.aucune] = { source = "aucune" }
    if R.source == "fenetre" then choisi = t.application end
    if R.source == "video" then choisi = t.video end
    if R.source == "aucune" then choisi = t.aucune end

    local app, actions_app = {}, {}
    local app_choisie = nil
    for _, f in ipairs(MENU.fenetres) do
        local texte = court(f.titre)
        if not actions_app[texte] then
            app[#app + 1] = texte
            actions_app[texte] = f
            if f.titre == R.fenetre_titre then app_choisie = texte end
        end
    end
    if not app_choisie and R.fenetre_titre ~= "" then
        -- Closed for now, or its title changed: stays chosen, and comes back when the program does.
        app_choisie = court(R.fenetre_titre)
        if not actions_app[app_choisie] then
            table.insert(app, 1, app_choisie)
            actions_app[app_choisie] = { titre = R.fenetre_titre, exe = R.fenetre_exe }
        end
    end
    if not app_choisie then
        app_choisie = "—"
        table.insert(app, 1, app_choisie)
    end

    local actuelle = R.video ~= "" and court(nom_fichier(R.video)) or t.aucun_fichier
    return {
        lieux = lieux, actions_lieu = actions_lieu, lieu_choisi = lieu_choisi,
        source = source, actions_source = actions_source, source_choisie = choisi or source[1],
        app = app, actions_app = actions_app, app_choisie = app_choisie,
        video = { actuelle, t.parcourir }, video_choisie = actuelle,
    }
end

-- The language changed while the options are open: the whole section follows at once.
local function suivre_langue()
    if langue_du_jeu() == MENU.langue then return end
    choisir_langue()
    local t, l = MENU.texte, MENU.lignes
    MENU.titre:SetText(FText(t.section))
    regler_textes(l.lieu, t.lieu_t, t.lieu_d)
    regler_textes(l.source, t.source_t, string.format(t.source_d, nom_lieu(LIEU_PAR_ID[MENU.lieu_choisi])))
    regler_textes(l.app, t.app_t, t.app_d)
    regler_textes(l.video, t.vid_t, t.vid_d)
    regler_textes(l.son, t.son_t, t.son_d)
    regler_textes(l.mains, t.mains_t, t.mains_d)
    MENU.etat = ""  -- messages about a missing window or file are rewritten in the new language
    MENU.decalage = -1
    journal("langue du menu : " .. MENU.langue)
end

local function appliquer_etat()
    local f = io.open(DOSSIER_MOD .. "etat.txt", "r")
    if not f then return end
    local etat = f:read("*l") or ""
    f:close()
    if etat == MENU.etat then return end
    MENU.etat = etat
    local t, l = MENU.texte, MENU.lignes
    regler_textes(l.app, t.app_t, etat == "fenetre_absente" and t.absente or t.app_d)
    local vid = t.vid_d
    if etat == "video_absente" then vid = t.video_absente end
    if etat == "video_refusee" then vid = t.video_refusee end
    regler_textes(l.video, t.vid_t, vid)
end

-- Called while the options are open: shows the state, and acts on what the player picked.
local function suivre_menu()
    local l = MENU.lignes
    suivre_langue()
    -- A file picked in the dialog.
    local fv = io.open(DOSSIER_MOD .. "video_choisie.txt", "r")
    if fv then
        local chemin = fv:read("*l")
        fv:close()
        os.remove(DOSSIER_MOD .. "video_choisie.txt")
        if chemin and chemin ~= "" then
            local R = REGLAGES_LIEU[MENU.lieu_choisi]
            R.video = chemin:gsub("\r$", "")
            R.source = "video"
            appliquer_lieu()
            ecrire_config()
        end
    end
    local maintenant = os.clock()
    if maintenant >= MENU.liste_demandee then
        MENU.liste_demandee = maintenant + 2
        local f = io.open(DOSSIER_MOD .. "lister.txt", "w")
        if f then f:close() end
        lire_liste()
    end
    local c = construire_choix()
    local t = MENU.texte
    local oui_non = { t.non, t.oui }

    -- What the player has just picked: anything different from what was last shown.
    local function lu(ligne)
        if #ligne.options == 0 then return nil end
        local valeur = ligne.liste.ComboBox:GetSelectedOption():ToString()
        if valeur ~= ligne.valeur and valeur ~= "" then
            -- Nobody can reach a dropdown this fast after the menu is built: this is not the player, so the setting stands.
            if os.clock() - MENU.cree_a < DELAI_AVANT_PREMIER_CHOIX then
                journal(string.format("menu : [%s] ignore juste apres la creation, on garde [%s]", valeur, tostring(ligne.valeur)))
                ligne.valeur = nil
                return nil
            end
            journal(string.format("menu : choix [%s] au lieu de [%s], %.1f s apres l'ouverture", valeur, tostring(ligne.valeur), os.clock() - (MENU.ouvert_depuis or 0)))
            return valeur
        end
        return nil
    end
    local change = false
    local v = lu(l.lieu)
    if v and c.actions_lieu[v] then
        MENU.lieu_choisi = c.actions_lieu[v]
        c = construire_choix()
    end
    if MENU.lieu_affiche ~= MENU.lieu_choisi then
        MENU.lieu_affiche = MENU.lieu_choisi
        regler_textes(l.source, t.source_t, string.format(t.source_d, nom_lieu(LIEU_PAR_ID[MENU.lieu_choisi])))
    end
    local R = REGLAGES_LIEU[MENU.lieu_choisi]
    v = lu(l.source)
    if v and c.actions_source[v] then
        R.source = c.actions_source[v].source
        if c.actions_source[v].numero then R.numero = c.actions_source[v].numero end
        change = true
    end
    v = lu(l.app)
    if v and c.actions_app[v] then
        R.fenetre_titre, R.fenetre_exe = c.actions_app[v].titre, c.actions_app[v].exe
        change = true
    end
    v = lu(l.video)
    if v == t.parcourir then
        local f = io.open(DOSSIER_MOD .. "parcourir.txt", "w")
        if f then f:close() end
    end
    v = lu(l.son)
    if v then
        R.video_son = v == t.oui and "1" or "0"
        change = true
    end
    v = lu(l.mains)
    if v then
        CONFIG.mains = v == t.oui and "1" or "0"
        change = true
    end
    if change then
        appliquer_lieu()
        ecrire_config()
        c = construire_choix()
        prochain_ecrans = 0  -- the screens and the hands follow at once
    end

    regler_options(l.lieu, c.lieux, c.lieu_choisi)
    regler_options(l.source, c.source, c.source_choisie)
    regler_options(l.app, c.app, c.app_choisie)
    regler_options(l.video, c.video, c.video_choisie)
    regler_options(l.son, oui_non, R.video_son ~= "0" and t.oui or t.non)
    regler_options(l.mains, oui_non, CONFIG.mains ~= "0" and t.oui or t.non)
    appliquer_etat()

    local COLLE, VISIBLE = 1, 4
    l.app.boite:SetVisibility(R.source == "fenetre" and VISIBLE or COLLE)
    l.video.boite:SetVisibility(R.source == "video" and VISIBLE or COLLE)
    l.son.boite:SetVisibility(R.source == "video" and VISIBLE or COLLE)
    -- The hands are copied in these two places; the setting itself is the same for both.
    l.mains.boite:SetVisibility((MENU.lieu_choisi == "jouer" or MENU.lieu_choisi == "clavarder") and VISIBLE or COLLE)

    -- The game's list starts below the section, whatever rows are showing.
    local hauteur = MENU.section:GetDesiredSize().Y
    if hauteur > 0 and math.abs(hauteur - MENU.decalage) > 0.5 then
        MENU.decalage = hauteur
        local m = MENU.marge_jeu
        MENU.boite_jeu.Slot:SetPadding({ Left = m.Left, Top = m.Top + hauteur + 24, Right = m.Right, Bottom = m.Bottom })
    end
end

-- The panel always says it is visible: what opens it is the HUD's switcher, which shows the panel's parent.
local function options_ouvertes(h)
    local p = h.UI_SettingsPanel
    local parent = p:GetParent()
    return valide(parent) and h.WidgetSwitcher:GetActiveWidgetIndex() == h.WidgetSwitcher:GetChildIndex(parent)
end

local function surveiller_menu()
    local t = os.clock()
    if t >= MENU.prochain_hud then
        MENU.prochain_hud = t + 1
        MENU.hud = hud()
        MENU.panneau = MENU.hud and MENU.hud.UI_SettingsPanel or nil
    end
    local p = MENU.panneau
    if not valide(p) or not valide(MENU.hud) then
        MENU.cree = false
        return
    end
    if not options_ouvertes(MENU.hud) then
        MENU.etait_ouvert = false
        return
    end
    if not MENU.etait_ouvert then
        MENU.etait_ouvert = true
        MENU.ouvert_depuis = t
        -- The menu opens on the place the player is in: what he changes is what he is looking at.
        if LIEU_COURANT then MENU.lieu_choisi = LIEU_COURANT.id end
    end
    if not MENU.cree then
        creer_menu(p)
        MENU.liste_demandee = 0
    end
    suivre_menu()
end

local function commande_menu(sortie)
    sortie[#sortie + 1] = "cree " .. tostring(MENU.cree) .. " etat " .. MENU.etat
    local R = REGLAGES_LIEU[MENU.lieu_choisi]
    sortie[#sortie + 1] = "lieu choisi=" .. MENU.lieu_choisi .. " courant=" .. (LIEU_COURANT and LIEU_COURANT.id or "aucun") .. " dll=" .. CONFIG.source
    sortie[#sortie + 1] = "source=" .. R.source .. " numero=" .. R.numero .. " mains=" .. CONFIG.mains .. " son=" .. R.video_son
    sortie[#sortie + 1] = "fenetre=" .. R.fenetre_titre .. " | " .. R.fenetre_exe .. " ; video=" .. R.video
    for _, nom_ligne in ipairs({ "lieu", "source", "app", "video", "son", "mains" }) do
        local l = MENU.lignes[nom_ligne]
        if l then
            sortie[#sortie + 1] = nom_ligne .. " : visible " .. tostring(l.boite:IsVisible()) .. " ; choix [" .. l.liste.ComboBox:GetSelectedOption():ToString()
                .. "] ; " .. l.liste.ComboBox:GetOptionCount() .. " options : " .. table.concat(l.options, " / ")
        end
    end
end

-- Probe: the sizes of a game's row title and of ours.
local function commande_polices(sortie)
    local p = MENU.panneau
    if not valide(p) then return end
    local function decrire(etiquette, w)
        sortie[#sortie + 1] = string.format("%s : police %s ; base %s ; finale %s ; bias %s/%s", etiquette,
            tostring(w.TextBlock.Font.Size), tostring(w["Default Font Size"] or w.DefaultFontSize), tostring(w["Final Size"] or w.FinalSize),
            tostring(w["PC Size Bias"] or w.PCSizeBias), tostring(w["Base Size Bias"] or w.BaseSizeBias))
    end
    local item_jeu = p.WB_TimeFormatSelector:GetParent():GetChildAt(0)
    decrire("jeu titre", item_jeu.WBP_Base_Text_Title)
    decrire("jeu desc", item_jeu.WBP_Base_Text_Desc)
    decrire("nous titre", MENU.lignes.source.item.WBP_Base_Text_Title)
    decrire("nous desc", MENU.lignes.source.item.WBP_Base_Text_Desc)
end

-- Probe: the game's languages and how the engine names the current one.
local function commande_langues(sortie)
    local i18n = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
    sortie[#sortie + 1] = "culture " .. i18n:GetCurrentCulture():ToString() .. " ; langue " .. i18n:GetCurrentLanguage():ToString()
        .. " ; locale " .. i18n:GetCurrentLocale():ToString()
    local p = MENU.panneau
    if valide(p) then
        local c = p.WB_LanguageSelector.ComboBox
        sortie[#sortie + 1] = "liste du jeu, " .. c:GetOptionCount() .. " options, choix [" .. c:GetSelectedOption():ToString() .. "]"
        for i = 0, c:GetOptionCount() - 1 do
            sortie[#sortie + 1] = "  " .. i .. " " .. c:GetOptionAtIndex(i):ToString()
        end
    else
        sortie[#sortie + 1] = "panneau pas encore vu"
    end
end

-- Probe: the game's own name for its activities, from the enum's display names.
local function commande_nom_activite(sortie)
    local enum = StaticFindObject("/Game/Core_Sessions/Activities/ENUM_Activities.ENUM_Activities")
    sortie[#sortie + 1] = "enum " .. nom(enum)
    local carte = enum.DisplayNameMap
    local vus = 0
    carte:ForEach(function(cle, valeur)
        local c = cle:get():ToString()
        if c:find("NewEnumerator16", 1, true) or vus < 3 then
            sortie[#sortie + 1] = "  " .. c .. " = " .. valeur:get():ToString()
        end
        vus = vus + 1
    end)
    sortie[#sortie + 1] = "  entrees " .. vus
    local textes = FindAllOf("UI_SingleActivity_C")
    sortie[#sortie + 1] = "UI_SingleActivity " .. tostring(textes and #textes or 0)
    for i, w in ipairs(textes or {}) do
        if i > 3 then break end
        local ok, t = pcall(function() return w.ActivityData end)
        sortie[#sortie + 1] = "  " .. nom(w):sub(-40) .. " " .. tostring(ok)
    end
end

local function commande_objets(sortie)
    DumpAllObjects()
    sortie[#sortie + 1] = "objets demandes"
end

-- Test: picks a language in the game's own dropdown, by its index.
local function commande_langue_choix(sortie, argument)
    local i = tonumber(argument or "")
    if not i or not valide(MENU.panneau) then sortie[#sortie + 1] = "refuse"; return end
    local c = MENU.panneau.WB_LanguageSelector.ComboBox
    c:SetSelectedIndex(i)
    sortie[#sortie + 1] = "choisi " .. c:GetSelectedOption():ToString()
end

-- Test: changes the game's language without saving it in the player's settings, then reads what the menu really shows.
local function commande_langue_code(sortie, argument)
    if not argument or not argument:match("^[%a%-]+$") then sortie[#sortie + 1] = "refuse"; return end
    StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary"):SetCurrentCulture(argument, false)
    sortie[#sortie + 1] = "demande " .. argument .. " ; langue " .. langue_du_jeu()
end

local function commande_textes_menu(sortie)
    sortie[#sortie + 1] = "langue " .. langue_du_jeu() .. " ; menu " .. tostring(MENU.langue) .. " ; activite " .. nom_jouer()
    sortie[#sortie + 1] = "section " .. MENU.titre:GetText():ToString()
    for _, nom_ligne in ipairs({ "source", "mains" }) do
        local l = MENU.lignes[nom_ligne]
        sortie[#sortie + 1] = nom_ligne .. " titre " .. l.item.WBP_Base_Text_Title.TextBlock:GetText():ToString()
        sortie[#sortie + 1] = nom_ligne .. " desc " .. l.item.WBP_Base_Text_Desc.TextBlock:GetText():ToString()
        sortie[#sortie + 1] = nom_ligne .. " choix " .. l.liste.ComboBox:GetSelectedOption():ToString()
    end
    sortie[#sortie + 1] = "haut section " .. string.format("%.0f", MENU.section:GetDesiredSize().Y)
end

-- Measure: uncaps the frame rate for this session only, and switches what the mod does, without the menu on screen.
local function commande_sans_limite(sortie, argument)
    local systeme = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local joueur = hud():GetOwningPlayer()
    if argument == "cap" then
        systeme:ExecuteConsoleCommand(hud(), "r.VSync 1", joueur)
    else
        systeme:ExecuteConsoleCommand(hud(), "r.VSync 0", joueur)
        systeme:ExecuteConsoleCommand(hud(), "t.MaxFPS 0", joueur)
    end
    sortie[#sortie + 1] = "limite " .. tostring(argument)
end

local function commande_mode(sortie, argument)
    local modes = {
        rien = { source = "aucune", mains = "0" },
        ecran = { source = "ecran", numero = "1", mains = "0" },
        ecran2 = { source = "ecran", numero = "2", mains = "0" },
        mains = { source = "aucune", mains = "1" },
        video = { source = "video", mains = "0", video_son = "0" },
        tout = { source = "ecran", numero = "1", mains = "1" },
        clav_rien = { lieu = "clavarder", source = "aucune", mains = "0" },
        clav_ecran = { lieu = "clavarder", source = "ecran", numero = "1", mains = "0" },
        clav_doigts = { lieu = "clavarder", source = "aucune", mains = "1" },
        clav_tout = { lieu = "clavarder", source = "ecran", numero = "1", mains = "1" },
    }
    local m = modes[argument or ""]
    if not m then sortie[#sortie + 1] = "refuse"; return end
    for cle, valeur in pairs(m) do
        if cle == "mains" then CONFIG.mains = valeur elseif cle ~= "lieu" then REGLAGES_LIEU[m.lieu or "jouer"][cle] = valeur end
    end
    appliquer_lieu()
    ecrire_config()
    prochain_ecrans = 0
    PIRE_TOUR_MS, POSE.pas, POSE.cumul, POSE.depart_mesure = 0, 0, 0, os.clock()
    sortie[#sortie + 1] = "mode " .. argument
end

-- Test: opens or closes the options, the way the game's own button does.
local function commande_bascule(sortie)
    local h = hud()
    h:EvSimulateSettingsPress()
    sortie[#sortie + 1] = "panneau visible " .. tostring(options_ouvertes(h))
end

-- Probe: what tells an open panel from a closed one.
local function commande_visibilite(sortie)
    local h = hud()
    local w = h.UI_SettingsPanel
    local chaine = {}
    while valide(w) and #chaine < 8 do
        local opacite = w.RenderOpacity
        local ok_v, v = pcall(function() return w:GetVisibility() end)
        chaine[#chaine + 1] = w:GetFName():ToString() .. "[" .. tostring(ok_v and v) .. "/" .. tostring(w:IsVisible()) .. "/" .. tostring(opacite) .. "]"
        local ok_p, parent = pcall(function() return w:GetParent() end)
        w = ok_p and parent or nil
    end
    sortie[#sortie + 1] = table.concat(chaine, " < ")
    sortie[#sortie + 1] = "HUD onglet " .. tostring(h.WidgetSwitcher:GetActiveWidgetIndex()) .. " ; bouton " .. nom(h.UI_Settings)
    local ok_s, nb = pcall(function() return h.WidgetSwitcher:GetChildrenCount() end)
    sortie[#sortie + 1] = "HUD enfants du switcher " .. tostring(ok_s and nb)
end

-- Test: selects an option of a row the way the dropdown does, "row:index".
local function commande_menu_choix(sortie, argument)
    local nom_ligne, index = (argument or ""):match("^(%a+):(%d+)$")
    local l = nom_ligne and MENU.lignes[nom_ligne]
    if not l then sortie[#sortie + 1] = "refuse"; return end
    l.liste.ComboBox:SetSelectedIndex(tonumber(index))
    sortie[#sortie + 1] = "choisi " .. l.liste.ComboBox:GetSelectedOption():ToString()
end

local function commande_images(sortie)
    local systeme = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    sortie[#sortie + 1] = "images " .. tostring(systeme:GetFrameCount())
end

-- Starts an activity of the current map, chosen by a fragment of its name.
local function commande_aller(sortie, fragment)
    if not fragment or not fragment:match("^[%w_]+$") then
        sortie[#sortie + 1] = "fragment refuse"
        return
    end
    local m = gestionnaire()
    if not m then sortie[#sortie + 1] = "pas de gestionnaire"; return end
    local fait = false
    m["Map Avatars to Activities"]:ForEach(function(cle, valeur)
        if not fait and nom(cle:get()):find(fragment, 1, true) then
            fait = true
            m:GoToActivity(valeur:get())
        end
    end)
    sortie[#sortie + 1] = "appel " .. tostring(fait) .. " activite " .. tostring(m.CurrentActivity)
end

local function commande_activites(sortie)
    local m = gestionnaire()
    if not m then return end
    m["Map Avatars to Activities"]:ForEach(function(cle)
        sortie[#sortie + 1] = nom(cle:get()):match("^(%S+)") or "?"
    end)
end

-- Probe: every activity of this map, with the name the player reads and the fields of its description.
local function commande_carte_activites(sortie)
    local m = gestionnaire()
    if not m then return end
    m["Map Avatars to Activities"]:ForEach(function(cle, valeur)
        local classe = nom(cle:get()):match("^(%S+)") or "?"
        local ok, texte = pcall(function()
            local activite = valeur:get()["Activity_62_425540C3495C387858C6DE9A5E397028"]
            return activite["Activitydisplayname_6_60705F9C4D9BA174E1A36698BF6A86DE"]:ToString()
        end)
        sortie[#sortie + 1] = classe .. " = " .. tostring(texte)
    end)
    sortie[#sortie + 1] = "activite " .. tostring(m.CurrentActivity) .. " lieu " .. tostring(m.CurrentLocation)
end

-- Probe: the tabs of the HUD, and every text on screen that holds a given word, to learn where the game keeps a name.
local function commande_hud_onglets(sortie, argument)
    local h = hud()
    if not h then return end
    local s = h.WidgetSwitcher
    if argument and argument:match("^%d+$") then s:SetActiveWidgetIndex(tonumber(argument)) end
    sortie[#sortie + 1] = "actif " .. s:GetActiveWidgetIndex()
    for i = 0, s:GetChildrenCount() - 1 do
        sortie[#sortie + 1] = i .. " " .. (s:GetChildAt(i):GetFullName():match("^(%S+)") or "?") .. " " .. (s:GetChildAt(i):GetFullName():match("([^%.]+)$") or "?")
    end
end

-- Probe: every text of the activity tab, with the widget that holds it. Argument: only the texts holding this word, wherever they are.
local function commande_textes_activites(sortie, mot)
    local vus = {}
    for _, t in ipairs(FindAllOf("TextBlock") or {}) do
        local ok, texte = pcall(function() return t:GetText():ToString() end)
        if ok and texte ~= "" then
            local plein = t:GetFullName()
            local garder = mot and texte:find(mot, 1, true) or (not mot and plein:find("Activit", 1, true))
            if garder and not plein:find("Default__", 1, true) then
                local chemin = plein:match("%.([^%.]+%.WidgetTree[^%.]*%.[^%.]+)$") or plein:sub(-70)
                vus[#vus + 1] = texte .. " <= " .. chemin
            end
        end
    end
    table.sort(vus)
    for _, l in ipairs(vus) do sortie[#sortie + 1] = l end
    sortie[#sortie + 1] = "textes " .. #vus
end

-- Probe: can the game's own string table give an activity's name in the player's language? And which materials do laptops expect?
local function commande_table_textes(sortie)
    for _, t in ipairs(FindAllOf("StringTable") or {}) do
        sortie[#sortie + 1] = "table " .. t:GetFullName()
    end
    local texte = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    for _, chemin in ipairs({ "ST_Localization", "/Game/Core_Sessions/Localization/ST_Localization.ST_Localization" }) do
        local ok, v = pcall(function() return texte:TextFromStringTable(FName(chemin), "Activity_Typing"):ToString() end)
        sortie[#sortie + 1] = "lu " .. chemin .. " : " .. tostring(ok) .. " " .. tostring(v)
    end
    local vus = {}
    for _, c in ipairs(FindAllOf("StaticMeshComponent") or {}) do
        local maillage = c.StaticMesh
        local n = nom(maillage)
        if n:find("Laptop", 1, true) and not vus[n] then
            vus[n] = true
            sortie[#sortie + 1] = n
            local ok, err = pcall(function()
                local mats = maillage.StaticMaterials
                for i = 1, #mats do
                    sortie[#sortie + 1] = "  " .. (i - 1) .. " " .. nom(mats[i].MaterialInterface)
                end
            end)
            if not ok then sortie[#sortie + 1] = "  erreur " .. tostring(err) end
        end
    end
end

-- Probe: every mesh of the level that may carry a screen, by the name of its material or its own name.
local function commande_ecrans_possibles(sortie)
    local MOTS = { "Screen", "Gif", "Flipbook", "Display", "Phone", "Laptop", "Tablet", "Monitor", "Handheld", "Television", "Kindle", "Ereader", "Widget3D" }
    local vus = {}
    for _, classe in ipairs({ "StaticMeshComponent", "SkeletalMeshComponent" }) do
        for _, c in ipairs(FindAllOf(classe) or {}) do
            local plein = c:GetFullName()
            local asset = classe == "StaticMeshComponent" and c.StaticMesh or c:GetSkinnedAsset()
            local maillage = nom(asset):match("([^%.]+)$") or "?"
            local mats = {}
            local garder = contient(maillage, MOTS)
            for slot = 0, 5 do
                local mat = c:GetMaterial(slot)
                if valide(mat) then
                    local texte = mat:GetFullName():match("([^%.]+)$") or "?"
                    mats[#mats + 1] = slot .. ":" .. texte:gsub("_%d+$", "")
                    if contient(texte, MOTS) then garder = true end
                end
            end
            if garder then
                local proprietaire = (plein:match("PersistentLevel%.([^%.]+)") or "?"):gsub("_%d+$", "")
                local cle = classe:sub(1, 2) .. " " .. maillage .. " | " .. table.concat(mats, " ") .. " | " .. proprietaire
                vus[cle] = (vus[cle] or 0) + 1
            end
        end
    end
    local lignes = {}
    for cle, n in pairs(vus) do lignes[#lignes + 1] = "x" .. n .. " " .. cle end
    table.sort(lignes, function(a, b) return a:sub(4) < b:sub(4) end)
    for _, l in ipairs(lignes) do sortie[#sortie + 1] = l end
end

-- Probe: where the hands and the laptop are for the avatar on show.
local function commande_sonde_frappe(sortie)
    local m = gestionnaire()
    if not m then return end
    sortie[#sortie + 1] = "activite " .. tostring(m.CurrentActivity)
    m["Map Avatars to Activities"]:ForEach(function(cle)
        local a = cle:get()
        if valide(a) and not a.bHidden then
            local classe = nom(a:GetClass()):match("([^%.]+)$") or "?"
            sortie[#sortie + 1] = "avatar " .. classe .. " " .. a:GetFullName():match("([^%.:]+)$")
            local corps = a.SkeletalMesh
            local presentes = {}
            for _, champ in ipairs(PARTIES) do
                local c = a[champ]
                presentes[#presentes + 1] = champ .. "=" .. ((valide(c) and valide(c:GetSkinnedAsset())) and "o" or "-")
            end
            sortie[#sortie + 1] = "parties " .. table.concat(presentes, " ")
            sortie[#sortie + 1] = string.format("ecart visible %.2f", v_long(v_moins(a.Hands:GetSocketLocation(FName("hand_L")), corps:GetSocketLocation(FName("hand_L")))))
            for _, os_nom in ipairs({ "upperarm_L", "upperarm_R", "forearm_L", "forearm_R", "hand_L", "hand_R", "index_03_L", "pinky_03_L", "thumb_03_L", "index_03_R", "pinky_03_R", "thumb_03_R" }) do
                sortie[#sortie + 1] = os_nom .. " " .. texte_vecteur(corps:GetSocketLocation(FName(os_nom)))
            end
            local main = corps:GetSocketLocation(FName("hand_L"))
            local meilleur, distance = nil, math.huge
            for _, e in ipairs(ECRANS) do
                if e.famille == "portable" and valide(e.composant) then
                    local ici = e.composant:K2_GetComponentLocation()
                    local d = v_long(v_moins(ici, main))
                    if d < distance then meilleur, distance = e.composant, d end
                end
            end
            if meilleur then
                local b = meilleur.StaticMesh:GetBounds()
                local e = meilleur:K2_GetComponentScale()
                sortie[#sortie + 1] = string.format("portable a %.1f cm, visible %s", distance, tostring(meilleur:IsVisible()))
                sortie[#sortie + 1] = "portable pos " .. texte_vecteur(meilleur:K2_GetComponentLocation())
                sortie[#sortie + 1] = "portable echelle " .. texte_vecteur(e) .. " origine " .. texte_vecteur(b.Origin) .. " etendue " .. texte_vecteur(b.BoxExtent)
                sortie[#sortie + 1] = "portable X " .. texte_vecteur(meilleur:GetForwardVector()) .. " Y " .. texte_vecteur(meilleur:GetRightVector()) .. " Z " .. texte_vecteur(meilleur:GetUpVector())
            end
        end
    end)
end

-- Probe: what is on show right now: the visible avatar's own objects, and any screen-like mesh in the room, with their materials.
local function commande_ici(sortie)
    local m = gestionnaire()
    if not m then return end
    sortie[#sortie + 1] = "activite " .. tostring(m.CurrentActivity) .. " lieu " .. tostring(m.CurrentLocation)
    local avatars = {}
    m["Map Avatars to Activities"]:ForEach(function(cle)
        local a = cle:get()
        if valide(a) and not a.bHidden then avatars[#avatars + 1] = a:GetFullName():match("([^%.:]+)$") end
    end)
    sortie[#sortie + 1] = "avatars " .. table.concat(avatars, ", ")
    local MOTS = { "Computer", "Monitor", "Laptop", "Screen", "Phone", "Tablet", "Handheld", "TV", "Television", "Console", "Switch", "Gameboy", "Display" }
    for _, c in ipairs(FindAllOf("StaticMeshComponent") or {}) do
        if c:IsVisible() then
            local plein = c:GetFullName()
            local maillage = nom(c.StaticMesh):match("([^%.]+)$") or "?"
            local du_avatar = false
            for _, a in ipairs(avatars) do
                if plein:find(a, 1, true) then du_avatar = true end
            end
            if du_avatar or contient(maillage, MOTS) then
                local mats = {}
                for slot = 0, 3 do
                    local mat = c:GetMaterial(slot)
                    if valide(mat) then mats[#mats + 1] = slot .. ":" .. (mat:GetFullName():match("([^%.]+)$") or "?") end
                end
                sortie[#sortie + 1] = (du_avatar and "A " or "M ") .. maillage .. " | " .. table.concat(mats, " ") .. " | " .. (plein:match("%.([^%.]+)%.[^%.]+$") or "?")
            end
        end
    end
end

local COMMANDES = {
    ping = function(sortie) sortie[#sortie + 1] = "pong" end,
    etat = commande_etat,
    images = commande_images,
    oublies = commande_oublies,
    temoin = commande_temoin,
    avatar = commande_avatar,
    panneau = commande_panneau,
    options = commande_options,
    menu = commande_menu,
    menu_choix = commande_menu_choix,
    polices = commande_polices,
    bascule = commande_bascule,
    visibilite = commande_visibilite,
    langues = commande_langues,
    langue_choix = commande_langue_choix,
    sans_limite = commande_sans_limite,
    mode = commande_mode,
    carte_activites = commande_carte_activites,
    ici = commande_ici,
    sonde_frappe = commande_sonde_frappe,
    frappe = function(sortie) FRAPPE.commande(sortie) end,
    ecrans_possibles = commande_ecrans_possibles,
    table_textes = commande_table_textes,
    hud_onglets = commande_hud_onglets,
    textes_activites = commande_textes_activites,
    langue_code = commande_langue_code,
    textes_menu = commande_textes_menu,
    nom_activite = commande_nom_activite,
    objets = commande_objets,
    pose = commande_pose,
    simule = commande_simule,
    carte = commande_carte,
    aller = commande_aller,
    activites = commande_activites,
}

-- ---------------------------------------------------------------- start

journal("mod charge dans " .. DOSSIER_MOD)
lire_config()
charger_module()

-- Everything runs on the game thread, from the camera pawn's tick. No LoopAsync: it runs on another thread that
-- shares the Lua state with the game thread, and at 60 calls per second that crashed inside UE4SS.dll.
local TICK = "/Game/Core_Sessions/Core/BP_CameraPawn.BP_CameraPawn_C:ReceiveTick"
prochain_ecrans = 0
local prochain_ordres, prochain_pas, prochain_menu, ACCROCHE = 0, 0, 0, false
local prochain_activite, PRET = 0, false

local function traiter_ordres()
    if not DIR then return end
    local f = io.open(ORDRES, "r")
    if not f then return end
    local ordre = f:read("*l")
    f:close()
    os.remove(ORDRES)
    if not ordre then return end
    local sortie = { "ordre " .. ordre }
    local commande, argument = ordre:match("^(%S+)%s*(%S*)")
    local fonction = COMMANDES[commande]
    if not fonction then
        sortie[#sortie + 1] = "inconnu"
    else
        local ok, err = pcall(fonction, sortie, argument)
        if not ok then sortie[#sortie + 1] = "ERREUR " .. tostring(err) end
    end
    repondre(sortie)
end

local function a_chaque_image()
    TICKS = TICKS + 1
    local t = os.clock()
    if t >= prochain_ordres then
        prochain_ordres = t + 0.5
        traiter_ordres()
    end
    -- A change of activity is seen at once, so the right picture is there when the screen comes into view.
    if t >= prochain_activite then
        prochain_activite = t + 0.2
        local g = GARDES.BP_LocationActivityManager_C
        if g and DERNIERE_ACTIVITE ~= nil and g.objet:IsValid() and g.objet.CurrentActivity ~= DERNIERE_ACTIVITE then
            prochain_ecrans = 0
        end
    end
    if t >= prochain_ecrans then
        prochain_ecrans = t + 1
        if not PRET and MODULE_CHARGE then PRET = fichier_existe(DOSSIER_MOD .. "pret.txt") end
        if PRET then
            local ok, err = pcall(tenir_ecrans)
            if not ok then journal("ERREUR tenir_ecrans " .. tostring(err)) end
        end
    end
    if t >= prochain_menu then
        prochain_menu = t + 0.15
        local ok, err = pcall(surveiller_menu)
        if not ok then
            prochain_menu = t + 5
            journal("ERREUR menu " .. tostring(err))
        end
    end
    -- 60 times a second is plenty for the hands, whatever the frame rate.
    if POSE.marche and t >= prochain_pas then
        prochain_pas = t + 1 / 60
        local ok, err = pcall(pas_pose)
        if not ok then
            POSE.marche = false
            journal("ERREUR pas_pose " .. tostring(err))
        end
    elseif FRAPPE.marche and t >= prochain_pas then
        prochain_pas = t + 1 / 60
        local ok, err = pcall(FRAPPE.pas)
        if not ok then
            FRAPPE.marche = false
            journal("ERREUR frappe " .. tostring(err))
        end
    end
end

-- The camera pawn's class is only loaded once the world starts.
RegisterBeginPlayPostHook(function()
    if ACCROCHE then return end
    local ok, err = pcall(RegisterHook, TICK, a_chaque_image)
    if ok then
        ACCROCHE = true
        journal("accroche a chaque image posee")
    elseif not POSE.erreur_accroche then
        POSE.erreur_accroche = true
        journal("accroche pas encore possible : " .. tostring(err))
    end
end)
