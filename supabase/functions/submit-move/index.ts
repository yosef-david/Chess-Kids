import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { Chess } from "npm:chess.js@1.4.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return Response.json({ error: "Method not allowed" }, { status: 405, headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const authorization = request.headers.get("Authorization");

    if (!supabaseUrl || !anonKey || !serviceKey || !authorization) {
      return Response.json({ error: "Server configuration or sign-in is missing" }, { status: 500, headers: corsHeaders });
    }

    const authClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await authClient.auth.getUser();
    const user = authData.user;
    if (authError || !user) {
      return Response.json({ error: "Authentication required" }, { status: 401, headers: corsHeaders });
    }

    const body = await request.json();
    const gameId = String(body.gameId || "");
    const uci = String(body.uci || "").toLowerCase();
    if (!/^[0-9a-f-]{36}$/i.test(gameId) || !/^[a-h][1-8][a-h][1-8][qrbn]?$/.test(uci)) {
      return Response.json({ error: "Invalid game or move format" }, { status: 400, headers: corsHeaders });
    }

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: game, error: gameError } = await admin
      .from("games")
      .select("id,white_player,black_player,status")
      .eq("id", gameId)
      .single();

    if (gameError || !game || game.status !== "active") {
      return Response.json({ error: "Game not found or no longer active" }, { status: 404, headers: corsHeaders });
    }
    if (user.id !== game.white_player && user.id !== game.black_player) {
      return Response.json({ error: "You are not a participant in this game" }, { status: 403, headers: corsHeaders });
    }

    const { data: savedMoves, error: movesError } = await admin
      .from("game_moves")
      .select("uci")
      .eq("game_id", gameId)
      .order("ply", { ascending: true });
    if (movesError) throw movesError;

    const chess = new Chess();
    for (const saved of savedMoves || []) {
      const previous = String(saved.uci);
      chess.move({
        from: previous.slice(0, 2),
        to: previous.slice(2, 4),
        promotion: previous[4] || "q",
      });
    }

    const expectedPlayer = chess.turn() === "w" ? game.white_player : game.black_player;
    if (expectedPlayer !== user.id) {
      return Response.json({ error: "It is not your turn" }, { status: 409, headers: corsHeaders });
    }

    let move;
    try {
      move = chess.move({
        from: uci.slice(0, 2),
        to: uci.slice(2, 4),
        promotion: uci[4] || "q",
      });
    } catch {
      move = null;
    }
    if (!move) {
      return Response.json({ error: "Illegal chess move" }, { status: 422, headers: corsHeaders });
    }

    const result = chess.isCheckmate()
      ? (chess.turn() === "w" ? "0-1" : "1-0")
      : chess.isDraw()
        ? "1/2-1/2"
        : null;

    const { error: saveError } = await admin.rpc("record_chess_move", {
      p_game_id: gameId,
      p_player_id: user.id,
      p_ply: (savedMoves || []).length + 1,
      p_san: move.san,
      p_uci: move.from + move.to + (move.promotion || ""),
      p_fen_after: chess.fen(),
      p_pgn: chess.pgn(),
      p_result: result,
    });

    if (saveError) {
      return Response.json({ error: saveError.message }, { status: 409, headers: corsHeaders });
    }

    const { data: clockState, error: clockError } = await admin
      .from("games")
      .select("white_time_ms,black_time_ms,active_color,clock_started_at,status,result")
      .eq("id", gameId)
      .single();
    if (clockError) throw clockError;

    return Response.json({
      move: move.san,
      fen: chess.fen(),
      pgn: chess.pgn(),
      result,
      clock: clockState,
    }, { headers: corsHeaders });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Unexpected server error" }, {
      status: 500,
      headers: corsHeaders,
    });
  }
});
