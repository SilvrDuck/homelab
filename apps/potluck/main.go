package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"

	"golang.org/x/crypto/bcrypt"
	"google.golang.org/genai"
)

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

const schema = `
CREATE TABLE IF NOT EXISTS users (
	id          INTEGER PRIMARY KEY AUTOINCREMENT,
	name        TEXT NOT NULL UNIQUE,
	secret_hash TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS items (
	id           INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id      INTEGER NOT NULL REFERENCES users(id),
	description  TEXT NOT NULL,
	contact_info TEXT NOT NULL,
	created_at   DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS matches (
	id         INTEGER PRIMARY KEY AUTOINCREMENT,
	item_a_id  INTEGER NOT NULL REFERENCES items(id),
	item_b_id  INTEGER NOT NULL REFERENCES items(id),
	created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
`

func initDB(path string) *sql.DB {
	log.Printf("[DB] Opening database at %s", path)
	db, err := sql.Open("sqlite", path)
	if err != nil {
		log.Fatalf("[DB] open error: %v", err)
	}
	db.SetMaxOpenConns(1) // SQLite single-writer
	if _, err := db.Exec(schema); err != nil {
		log.Fatalf("[DB] schema init error: %v", err)
	}
	log.Printf("[DB] Schema initialized successfully")
	return db
}

// ---------------------------------------------------------------------------
// Session management (in-memory token -> user_id map)
// ---------------------------------------------------------------------------

type sessionStore struct {
	mu       sync.RWMutex
	sessions map[string]int64 // token -> user_id
	key      []byte           // HMAC signing key
}

func newSessionStore() *sessionStore {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		log.Fatalf("generate session key: %v", err)
	}
	return &sessionStore{sessions: make(map[string]int64), key: key}
}

func (s *sessionStore) create(userID int64) string {
	raw := make([]byte, 32)
	rand.Read(raw)
	token := hex.EncodeToString(raw)

	s.mu.Lock()
	s.sessions[token] = userID
	s.mu.Unlock()
	return token
}

func (s *sessionStore) get(token string) (int64, bool) {
	s.mu.RLock()
	uid, ok := s.sessions[token]
	s.mu.RUnlock()
	return uid, ok
}

func (s *sessionStore) delete(token string) {
	s.mu.Lock()
	delete(s.sessions, token)
	s.mu.Unlock()
}

// ---------------------------------------------------------------------------
// Gemini matching
// ---------------------------------------------------------------------------

type matcher struct {
	client *genai.Client
	model  string
}

func newMatcher(ctx context.Context) *matcher {
	apiKey := os.Getenv("GEMINI_API_KEY")
	if apiKey == "" {
		log.Println("WARNING: GEMINI_API_KEY not set — matching will be disabled")
		return nil
	}
	client, err := genai.NewClient(ctx, &genai.ClientConfig{
		APIKey:  apiKey,
		Backend: genai.BackendGeminiAPI,
	})
	if err != nil {
		log.Fatalf("create gemini client: %v", err)
	}
	return &matcher{client: client, model: "gemini-2.5-flash"}
}

type otherItem struct {
	ID          int64  `json:"id"`
	Description string `json:"description"`
}

func (m *matcher) findMatches(ctx context.Context, newItem string, others []otherItem) ([]int64, error) {
	if m == nil {
		log.Printf("[Gemini] Matcher is nil (no API key), skipping")
		return nil, nil
	}
	if len(others) == 0 {
		log.Printf("[Gemini] No other items to compare against, skipping")
		return nil, nil
	}

	log.Printf("[Gemini] Checking %q against %d other item(s)", newItem, len(others))

	var sb strings.Builder
	for _, o := range others {
		fmt.Fprintf(&sb, "- ID %d: %s\n", o.ID, o.Description)
	}

	prompt := fmt.Sprintf(`Tu aides a organiser une soiree/fete ou chacun ramene a boire et a manger.
Un nouvel element vient d'etre ajoute : "%s".

Voici les elements deja prevus par d'autres personnes :
%s
Lesquels de ces elements sont essentiellement la meme chose que le nouvel element ?
Ne matche que les elements qui sont clairement la meme chose (ex: "guacamole" et "guac maison" = match, mais "guacamole" et "salsa" = pas match).
"pastis" et "ricard" = match. "rose" et "bouteille de rose" = match. "chips" et "chips au paprika" = match.

Reponds UNIQUEMENT avec un tableau JSON d'IDs. Si aucun match, reponds avec un tableau vide [].
Exemple de reponse : [3, 7]`, newItem, sb.String())

	log.Printf("[Gemini] Sending request to %s...", m.model)
	start := time.Now()
	resp, err := m.client.Models.GenerateContent(ctx, m.model, genai.Text(prompt), nil)
	elapsed := time.Since(start)
	if err != nil {
		log.Printf("[Gemini] API error after %s: %v", elapsed.Round(time.Millisecond), err)
		return nil, fmt.Errorf("gemini call: %w", err)
	}

	text := resp.Text()
	log.Printf("[Gemini] Response received in %s: %s", elapsed.Round(time.Millisecond), strings.TrimSpace(text))

	text = strings.TrimSpace(text)
	// Strip markdown code fences if present
	text = strings.TrimPrefix(text, "```json")
	text = strings.TrimPrefix(text, "```")
	text = strings.TrimSuffix(text, "```")
	text = strings.TrimSpace(text)

	var ids []int64
	if err := json.Unmarshal([]byte(text), &ids); err != nil {
		log.Printf("[Gemini] Parse error: %v (raw response: %q)", err, text)
		return nil, nil // non-fatal
	}
	log.Printf("[Gemini] Matched item IDs: %v", ids)
	return ids, nil
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

type app struct {
	db       *sql.DB
	sessions *sessionStore
	matcher  *matcher
}

// --- Auth helpers ---

func (a *app) authenticate(r *http.Request) (int64, bool) {
	cookie, err := r.Cookie("session")
	if err != nil {
		return 0, false
	}
	return a.sessions.get(cookie.Value)
}

func setSessionCookie(w http.ResponseWriter, token string) {
	http.SetCookie(w, &http.Cookie{
		Name:     "session",
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   86400 * 30, // 30 days
	})
}

// --- JSON helpers ---

func jsonErr(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func jsonOK(w http.ResponseWriter, data any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

// --- Handlers ---

func (a *app) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonErr(w, "method not allowed", 405)
		return
	}

	var req struct {
		Name   string `json:"name"`
		Secret string `json:"secret"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		log.Printf("[Login] Invalid JSON body: %v", err)
		jsonErr(w, "invalid json", 400)
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	req.Secret = strings.TrimSpace(req.Secret)
	if req.Name == "" || req.Secret == "" {
		log.Printf("[Login] Missing name or secret")
		jsonErr(w, "name and secret are required", 400)
		return
	}

	log.Printf("[Login] Attempt for name=%q", req.Name)

	// Try to find existing user
	var userID int64
	var secretHash string
	err := a.db.QueryRow("SELECT id, secret_hash FROM users WHERE name = ?", req.Name).Scan(&userID, &secretHash)
	if err == sql.ErrNoRows {
		// Register new user
		log.Printf("[Login] New user, registering %q", req.Name)
		hash, err := bcrypt.GenerateFromPassword([]byte(req.Secret), bcrypt.DefaultCost)
		if err != nil {
			log.Printf("[Login] bcrypt error: %v", err)
			jsonErr(w, "internal error", 500)
			return
		}
		res, err := a.db.Exec("INSERT INTO users (name, secret_hash) VALUES (?, ?)", req.Name, string(hash))
		if err != nil {
			log.Printf("[Login] DB insert error: %v", err)
			jsonErr(w, "internal error", 500)
			return
		}
		userID, _ = res.LastInsertId()
		log.Printf("[Login] Registered user %q with id=%d", req.Name, userID)
	} else if err != nil {
		log.Printf("[Login] DB query error: %v", err)
		jsonErr(w, "internal error", 500)
		return
	} else {
		// Verify secret
		if err := bcrypt.CompareHashAndPassword([]byte(secretHash), []byte(req.Secret)); err != nil {
			log.Printf("[Login] Invalid secret for user %q (id=%d)", req.Name, userID)
			jsonErr(w, "invalid secret for this name", 401)
			return
		}
		log.Printf("[Login] Authenticated existing user %q (id=%d)", req.Name, userID)
	}

	token := a.sessions.create(userID)
	setSessionCookie(w, token)
	log.Printf("[Login] Session created for user %q (id=%d)", req.Name, userID)
	jsonOK(w, map[string]any{"ok": true, "name": req.Name})
}

func (a *app) handleLogout(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie("session"); err == nil {
		if uid, ok := a.sessions.get(cookie.Value); ok {
			log.Printf("[Logout] user_id=%d", uid)
		}
		a.sessions.delete(cookie.Value)
	}
	http.SetCookie(w, &http.Cookie{
		Name:   "session",
		Value:  "",
		Path:   "/",
		MaxAge: -1,
	})
	jsonOK(w, map[string]bool{"ok": true})
}

func (a *app) handleMe(w http.ResponseWriter, r *http.Request) {
	userID, ok := a.authenticate(r)
	if !ok {
		jsonErr(w, "not authenticated", 401)
		return
	}
	var name string
	a.db.QueryRow("SELECT name FROM users WHERE id = ?", userID).Scan(&name)
	log.Printf("[Me] user_id=%d name=%q", userID, name)
	jsonOK(w, map[string]any{"id": userID, "name": name})
}

type itemResponse struct {
	ID          int64          `json:"id"`
	Description string         `json:"description"`
	ContactInfo string         `json:"contact_info"`
	CreatedAt   string         `json:"created_at"`
	Matches     []matchContact `json:"matches,omitempty"`
}

type matchContact struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	ContactInfo string `json:"contact_info"`
}

func (a *app) handleGetItems(w http.ResponseWriter, r *http.Request) {
	userID, ok := a.authenticate(r)
	if !ok {
		jsonErr(w, "not authenticated", 401)
		return
	}
	log.Printf("[GetItems] user_id=%d", userID)

	// Step 1: collect all items (close cursor before any further queries to avoid SQLite deadlock)
	rows, err := a.db.Query(`SELECT id, description, contact_info, created_at FROM items WHERE user_id = ? ORDER BY created_at DESC`, userID)
	if err != nil {
		log.Printf("[GetItems] query error: %v", err)
		jsonErr(w, "internal error", 500)
		return
	}
	var items []itemResponse
	for rows.Next() {
		var it itemResponse
		if err := rows.Scan(&it.ID, &it.Description, &it.ContactInfo, &it.CreatedAt); err != nil {
			log.Printf("[GetItems] scan error: %v", err)
		}
		items = append(items, it)
	}
	rows.Close() // close BEFORE any nested queries

	log.Printf("[GetItems] found %d items for user_id=%d", len(items), userID)

	// Step 2: for each item, fetch matches (cursor is now closed, no deadlock)
	for i := range items {
		matchRows, err := a.db.Query(`
			SELECT u.name, i.description, i.contact_info
			FROM matches m
			JOIN items i ON (i.id = CASE WHEN m.item_a_id = ? THEN m.item_b_id ELSE m.item_a_id END)
			JOIN users u ON u.id = i.user_id
			WHERE m.item_a_id = ? OR m.item_b_id = ?
		`, items[i].ID, items[i].ID, items[i].ID)
		if err != nil {
			log.Printf("[GetItems] match query error for item %d: %v", items[i].ID, err)
			continue
		}
		for matchRows.Next() {
			var mc matchContact
			if err := matchRows.Scan(&mc.Name, &mc.Description, &mc.ContactInfo); err != nil {
				log.Printf("[GetItems] match scan error: %v", err)
			}
			items[i].Matches = append(items[i].Matches, mc)
		}
		matchRows.Close()
		if len(items[i].Matches) > 0 {
			log.Printf("[GetItems] item %d (%q) has %d match(es)", items[i].ID, items[i].Description, len(items[i].Matches))
		}
	}

	if items == nil {
		items = []itemResponse{}
	}
	jsonOK(w, items)
}

func (a *app) handleAddItem(w http.ResponseWriter, r *http.Request) {
	userID, ok := a.authenticate(r)
	if !ok {
		jsonErr(w, "not authenticated", 401)
		return
	}

	var req struct {
		Description string `json:"description"`
		ContactInfo string `json:"contact_info"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		log.Printf("[AddItem] Invalid JSON body: %v", err)
		jsonErr(w, "invalid json", 400)
		return
	}
	req.Description = strings.TrimSpace(req.Description)
	req.ContactInfo = strings.TrimSpace(req.ContactInfo)
	if req.Description == "" || req.ContactInfo == "" {
		log.Printf("[AddItem] Missing description or contact_info")
		jsonErr(w, "description and contact_info are required", 400)
		return
	}

	log.Printf("[AddItem] user_id=%d description=%q contact=%q", userID, req.Description, req.ContactInfo)

	// Insert the item
	res, err := a.db.Exec("INSERT INTO items (user_id, description, contact_info) VALUES (?, ?, ?)",
		userID, req.Description, req.ContactInfo)
	if err != nil {
		log.Printf("[AddItem] DB insert error: %v", err)
		jsonErr(w, "internal error", 500)
		return
	}
	newID, _ := res.LastInsertId()
	log.Printf("[AddItem] Inserted item id=%d", newID)

	// Fetch all other users' items for matching
	rows, err := a.db.Query("SELECT id, description FROM items WHERE user_id != ?", userID)
	if err != nil {
		log.Printf("[AddItem] Error fetching other items: %v", err)
	} else {
		var others []otherItem
		for rows.Next() {
			var o otherItem
			rows.Scan(&o.ID, &o.Description)
			others = append(others, o)
		}
		rows.Close()

		log.Printf("[AddItem] Found %d item(s) from other users to compare against", len(others))

		if len(others) > 0 {
			ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
			defer cancel()
			matchIDs, err := a.matcher.findMatches(ctx, req.Description, others)
			if err != nil {
				log.Printf("[AddItem] Matching error: %v", err)
			}
			for _, matchedItemID := range matchIDs {
				// Verify the matched ID is actually in our list (safety check)
				valid := false
				for _, o := range others {
					if o.ID == matchedItemID {
						valid = true
						break
					}
				}
				if valid {
					_, err := a.db.Exec("INSERT INTO matches (item_a_id, item_b_id) VALUES (?, ?)", newID, matchedItemID)
					if err != nil {
						log.Printf("[AddItem] Error inserting match (%d, %d): %v", newID, matchedItemID, err)
					} else {
						log.Printf("[AddItem] Created match: item %d <-> item %d", newID, matchedItemID)
					}
				} else {
					log.Printf("[AddItem] Gemini returned invalid item ID %d, ignoring", matchedItemID)
				}
			}
		}
	}

	log.Printf("[AddItem] Done, responding with id=%d", newID)
	jsonOK(w, map[string]any{"ok": true, "id": newID})
}

func (a *app) handleDeleteItem(w http.ResponseWriter, r *http.Request) {
	userID, ok := a.authenticate(r)
	if !ok {
		jsonErr(w, "not authenticated", 401)
		return
	}

	// Extract item ID from path: /api/items/{id}
	parts := strings.Split(r.URL.Path, "/")
	if len(parts) < 4 {
		log.Printf("[DeleteItem] Missing item ID in path: %s", r.URL.Path)
		jsonErr(w, "missing item id", 400)
		return
	}
	itemID, err := strconv.ParseInt(parts[len(parts)-1], 10, 64)
	if err != nil {
		log.Printf("[DeleteItem] Invalid item ID in path: %s", parts[len(parts)-1])
		jsonErr(w, "invalid item id", 400)
		return
	}

	log.Printf("[DeleteItem] user_id=%d item_id=%d", userID, itemID)

	// Verify ownership
	var ownerID int64
	err = a.db.QueryRow("SELECT user_id FROM items WHERE id = ?", itemID).Scan(&ownerID)
	if err != nil || ownerID != userID {
		log.Printf("[DeleteItem] Item %d not found or not owned by user %d (owner=%d, err=%v)", itemID, userID, ownerID, err)
		jsonErr(w, "not found", 404)
		return
	}

	// Delete matches first, then the item
	if res, err := a.db.Exec("DELETE FROM matches WHERE item_a_id = ? OR item_b_id = ?", itemID, itemID); err != nil {
		log.Printf("[DeleteItem] Error deleting matches for item %d: %v", itemID, err)
	} else {
		n, _ := res.RowsAffected()
		if n > 0 {
			log.Printf("[DeleteItem] Removed %d match(es) for item %d", n, itemID)
		}
	}

	if _, err := a.db.Exec("DELETE FROM items WHERE id = ?", itemID); err != nil {
		log.Printf("[DeleteItem] Error deleting item %d: %v", itemID, err)
		jsonErr(w, "internal error", 500)
		return
	}

	log.Printf("[DeleteItem] Deleted item %d", itemID)
	jsonOK(w, map[string]bool{"ok": true})
}

// ---------------------------------------------------------------------------
// HTML template (embedded)
// ---------------------------------------------------------------------------

const indexHTML = `<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>La Roulette du Pastis</title>
<script src="https://cdn.tailwindcss.com"></script>
<style>
  body { font-family: 'Inter', system-ui, sans-serif; }
  .fade-in { animation: fadeIn 0.3s ease-in; }
  @keyframes fadeIn { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }
</style>
</head>
<body class="bg-gradient-to-br from-yellow-50 to-amber-100 min-h-screen">

<div id="app" class="max-w-2xl mx-auto px-4 py-8">

  <!-- Header -->
  <div class="text-center mb-8">
    <h1 class="text-4xl font-bold text-amber-900 mb-2">La Roulette du Pastis</h1>
    <p class="text-amber-700 text-lg italic">Qui ramene quoi ? Personne le sait... sauf si t'as le meme truc qu'un autre.</p>
  </div>

  <!-- Login Screen -->
  <div id="login-screen" class="bg-white rounded-2xl shadow-lg p-8 fade-in">
    <h2 class="text-xl font-semibold text-gray-800 mb-4">Rejoindre la teuf</h2>
    <p class="text-gray-500 text-sm mb-6">Entre ton nom et un mot de passe secret. Utilise la meme combinaison pour revenir plus tard.</p>
    <div class="space-y-4">
      <div>
        <label class="block text-sm font-medium text-gray-700 mb-1">Ton blaze</label>
        <input id="login-name" type="text" placeholder="ex: Jean-Pastis"
          class="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-amber-400 focus:border-transparent outline-none">
      </div>
      <div>
        <label class="block text-sm font-medium text-gray-700 mb-1">Mot de passe secret</label>
        <input id="login-secret" type="password" placeholder="un truc que toi seul connais"
          class="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-amber-400 focus:border-transparent outline-none">
      </div>
      <div id="login-error" class="text-red-600 text-sm hidden"></div>
      <button onclick="doLogin()" id="login-btn"
        class="w-full bg-amber-600 text-white py-2 px-4 rounded-lg font-medium hover:bg-amber-700 transition-colors disabled:opacity-50">
        C'est parti !
      </button>
    </div>
  </div>

  <!-- Main Screen (hidden until logged in) -->
  <div id="main-screen" class="hidden">

    <!-- User bar -->
    <div class="flex items-center justify-between mb-6 bg-white rounded-xl shadow-sm px-4 py-3">
      <span class="text-gray-700">Salut <strong id="user-name"></strong> !</span>
      <button onclick="doLogout()" class="text-sm text-amber-600 hover:text-amber-800 font-medium">Se deconnecter</button>
    </div>

    <!-- Add item form -->
    <div class="bg-white rounded-2xl shadow-lg p-6 mb-6 fade-in">
      <h2 class="text-lg font-semibold text-gray-800 mb-4">Tu ramenes quoi ?</h2>
      <div class="space-y-3">
        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Ce que tu apportes</label>
          <input id="item-desc" type="text" placeholder="ex: Une bouteille de pastis, du guacamole maison..."
            class="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-amber-400 focus:border-transparent outline-none">
        </div>
        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Tes coordonnees</label>
          <input id="item-contact" type="text" placeholder="ex: 06 12 34 56 78 / jean@pastis.fr"
            class="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-amber-400 focus:border-transparent outline-none">
        </div>
        <div id="add-error" class="text-red-600 text-sm hidden"></div>
        <button onclick="doAddItem()" id="add-btn"
          class="w-full bg-amber-600 text-white py-2 px-4 rounded-lg font-medium hover:bg-amber-700 transition-colors disabled:opacity-50">
          Ajouter
        </button>
      </div>
    </div>

    <!-- Items list -->
    <div id="items-section">
      <h2 class="text-lg font-semibold text-gray-800 mb-3">Ce que tu ramenes</h2>
      <div id="items-list" class="space-y-3">
        <!-- filled by JS -->
      </div>
      <div id="no-items" class="hidden text-center text-gray-400 py-8">
        T'as encore rien ajoute. Allez, fais un effort !
      </div>
    </div>

    <!-- Info -->
    <div class="mt-8 bg-amber-50 border border-amber-200 rounded-xl p-4 text-sm text-amber-800">
      <strong>Comment ca marche :</strong> Personne ne voit ce que tu ramenes.
      Mais si quelqu'un d'autre ramene la meme chose, vous verrez tous les deux les coordonnees de l'autre
      pour vous organiser et eviter de vous pointer avec 5 bouteilles de rose.
    </div>

  </div>
</div>

<script>
// --- API helpers ---
async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...opts,
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || 'Un truc a foire');
  return data;
}

// --- Login ---
async function doLogin() {
  const name = document.getElementById('login-name').value.trim();
  const secret = document.getElementById('login-secret').value.trim();
  const errEl = document.getElementById('login-error');
  const btn = document.getElementById('login-btn');

  errEl.classList.add('hidden');
  if (!name || !secret) {
    errEl.textContent = 'Remplis les deux champs !';
    errEl.classList.remove('hidden');
    return;
  }

  btn.disabled = true;
  btn.textContent = 'Connexion...';
  try {
    const data = await api('/api/login', {
      method: 'POST',
      body: JSON.stringify({ name, secret }),
    });
    showMainScreen(data.name);
  } catch (e) {
    errEl.textContent = e.message;
    errEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
    btn.textContent = "C'est parti !";
  }
}

async function doLogout() {
  await api('/api/logout', { method: 'POST' });
  document.getElementById('main-screen').classList.add('hidden');
  document.getElementById('login-screen').classList.remove('hidden');
  document.getElementById('login-name').value = '';
  document.getElementById('login-secret').value = '';
}

// --- Items ---
async function loadItems() {
  const items = await api('/api/items');
  const list = document.getElementById('items-list');
  const noItems = document.getElementById('no-items');

  if (items.length === 0) {
    list.innerHTML = '';
    noItems.classList.remove('hidden');
    return;
  }

  noItems.classList.add('hidden');
  list.innerHTML = items.map(item => {
    const matchesHTML = item.matches && item.matches.length > 0
      ? item.matches.map(m => ` + "`" + `
        <div class="mt-2 bg-red-50 border border-red-200 rounded-lg p-3 text-sm">
          <div class="font-medium text-red-700">Doublon repere !</div>
          <div class="text-red-600 mt-1">
            <strong>${esc(m.name)}</strong> ramene aussi :
            <em>${esc(m.description)}</em>
          </div>
          <div class="text-red-500 mt-1">Contact : ${esc(m.contact_info)}</div>
        </div>
      ` + "`" + `).join('')
      : '';

    return ` + "`" + `
      <div class="bg-white rounded-xl shadow-sm p-4 fade-in">
        <div class="flex items-start justify-between">
          <div class="flex-1">
            <div class="font-medium text-gray-800">${esc(item.description)}</div>
            <div class="text-sm text-gray-500 mt-1">Contact : ${esc(item.contact_info)}</div>
          </div>
          <button onclick="doDeleteItem(${item.id})"
            class="ml-3 text-gray-400 hover:text-red-500 transition-colors" title="Supprimer">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
            </svg>
          </button>
        </div>
        ${matchesHTML}
      </div>
    ` + "`" + `;
  }).join('');
}

async function doAddItem() {
  const desc = document.getElementById('item-desc').value.trim();
  const contact = document.getElementById('item-contact').value.trim();
  const errEl = document.getElementById('add-error');
  const btn = document.getElementById('add-btn');

  errEl.classList.add('hidden');
  if (!desc || !contact) {
    errEl.textContent = 'Remplis les deux champs !';
    errEl.classList.remove('hidden');
    return;
  }

  btn.disabled = true;
  btn.textContent = 'Ajout en cours (on verifie les doublons)...';
  try {
    await api('/api/items', {
      method: 'POST',
      body: JSON.stringify({ description: desc, contact_info: contact }),
    });
    document.getElementById('item-desc').value = '';
    // Keep contact info for convenience (likely same for multiple items)
    await loadItems();
  } catch (e) {
    errEl.textContent = e.message;
    errEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Ajouter';
  }
}

async function doDeleteItem(id) {
  if (!confirm('Supprimer cet element ?')) return;
  try {
    await api('/api/items/' + id, { method: 'DELETE' });
    await loadItems();
  } catch (e) {
    alert(e.message);
  }
}

// --- Utility ---
function esc(s) {
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}

// --- Init ---
async function showMainScreen(name) {
  document.getElementById('user-name').textContent = name;
  document.getElementById('login-screen').classList.add('hidden');
  document.getElementById('main-screen').classList.remove('hidden');
  await loadItems();
}

// Check if already logged in
(async () => {
  try {
    const me = await api('/api/me');
    showMainScreen(me.name);
  } catch {
    // not logged in, show login
  }

  // Enter key support
  document.getElementById('login-secret').addEventListener('keydown', e => {
    if (e.key === 'Enter') doLogin();
  });
  document.getElementById('login-name').addEventListener('keydown', e => {
    if (e.key === 'Enter') document.getElementById('login-secret').focus();
  });
  document.getElementById('item-desc').addEventListener('keydown', e => {
    if (e.key === 'Enter') document.getElementById('item-contact').focus();
  });
  document.getElementById('item-contact').addEventListener('keydown', e => {
    if (e.key === 'Enter') doAddItem();
  });
})();
</script>

</body>
</html>`

// ---------------------------------------------------------------------------
// Logging middleware
// ---------------------------------------------------------------------------

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rec, r)
		log.Printf("[HTTP] %s %s -> %d (%s)", r.Method, r.URL.Path, rec.status, time.Since(start).Round(time.Millisecond))
	})
}

// ---------------------------------------------------------------------------
// Router & main
// ---------------------------------------------------------------------------

func main() {
	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds)
	log.Println("Starting La Roulette du Pastis...")

	db := initDB("potluck.db")
	defer db.Close()
	log.Println("Database initialized")

	ctx := context.Background()
	m := newMatcher(ctx)
	if m != nil {
		log.Println("Gemini matcher initialized (model: gemini-2.5-flash)")
	}

	a := &app{db: db, sessions: newSessionStore(), matcher: m}

	mux := http.NewServeMux()

	// Serve HTML
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, indexHTML)
	})

	// API
	mux.HandleFunc("/api/login", a.handleLogin)
	mux.HandleFunc("/api/logout", a.handleLogout)
	mux.HandleFunc("/api/me", a.handleMe)
	mux.HandleFunc("/api/items", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			a.handleGetItems(w, r)
		case http.MethodPost:
			a.handleAddItem(w, r)
		default:
			jsonErr(w, "method not allowed", 405)
		}
	})
	mux.HandleFunc("/api/items/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			a.handleDeleteItem(w, r)
		} else {
			jsonErr(w, "method not allowed", 405)
		}
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("La Roulette du Pastis tourne sur http://localhost:%s", port)
	log.Fatal(http.ListenAndServe(":"+port, loggingMiddleware(mux)))
}
