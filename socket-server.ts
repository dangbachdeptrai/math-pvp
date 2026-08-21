import "dotenv/config";
import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { Server, Socket } from "socket.io";
import { createClient } from "@supabase/supabase-js";
import { demoAnswerKeys, demoQuestions } from "./src/lib/demo-data";

type Option = "A" | "B" | "C" | "D";
type Player = { id: string; name: string; answers: Record<string, Option>; score: number; finished: boolean };
type Round = { examId: string; questionIds: string[]; keys: Record<string, Option>; durationSeconds: number };
type Room = { id: string; round: Round; startsAt: number; players: Map<string, Player>; timeout: NodeJS.Timeout };

const port = Number(process.env.SOCKET_PORT || 3001);
const httpServer = createServer();
const io = new Server(httpServer, { cors: { origin: (process.env.NEXT_PUBLIC_APP_URL || "http://localhost:3000").split(","), methods: ["GET", "POST"] } });
const queues = new Map<string, string[]>();
const rooms = new Map<string, Room>();
const socketRoom = new Map<string, string>();
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const admin = supabaseUrl && serviceKey ? createClient(supabaseUrl, serviceKey) : null;

async function resolvePlayerName(socket: Socket) {
  const token = socket.handshake.auth?.accessToken;
  if (!admin || typeof token !== "string") return String(socket.handshake.auth?.displayName || "Người chơi").slice(0, 40);
  const { data } = await admin.auth.getUser(token);
  return String(data.user?.user_metadata?.full_name || data.user?.email?.split("@")[0] || "Người chơi").slice(0, 40);
}

async function loadRound(examId: string): Promise<Round | null> {
  if (!admin) {
    const questions = demoQuestions[examId];
    if (!questions) return null;
    return { examId, questionIds: questions.map((question) => question.id), keys: Object.fromEntries(questions.map((question) => [question.id, demoAnswerKeys[question.id]])), durationSeconds: 600 };
  }
  const [{ data: exam, error: examError }, { data: questions, error: questionError }, { data: keys, error: keyError }] = await Promise.all([
    admin.from("exams").select("id,duration_minutes,is_published").eq("id", examId).eq("is_published", true).single(),
    admin.from("exam_questions").select("id").eq("exam_id", examId).order("position"),
    admin.from("question_answer_keys").select("question_id,correct_option").eq("exam_id", examId)
  ]);
  if (examError || questionError || keyError || !exam || !questions?.length || keys?.length !== questions.length) return null;
  return { examId, questionIds: questions.map((item) => item.id), keys: Object.fromEntries(keys.map((item) => [item.question_id, item.correct_option as Option])), durationSeconds: Math.min(Number(exam.duration_minutes) * 60, 1800) };
}

function state(room: Room) {
  return { roomId: room.id, examId: room.round.examId, durationSeconds: room.round.durationSeconds, startsAt: room.startsAt, players: [...room.players.values()].map(({ id, name, score, finished }) => ({ id, name, score, finished })) };
}

function endRoom(room: Room, reason: "completed" | "time_up" | "forfeit") {
  clearTimeout(room.timeout); rooms.delete(room.id);
  const ranking = [...room.players.values()].map(({ id, name, score, finished }) => ({ id, name, score, finished })).sort((a, b) => b.score - a.score);
  for (const player of room.players.values()) socketRoom.delete(player.id);
  io.to(room.id).emit("match_result", { roomId: room.id, reason, ranking });
}

function leaveQueue(socketId: string) { for (const [examId, entries] of queues.entries()) { const next = entries.filter((id) => id !== socketId); if (next.length) queues.set(examId, next); else queues.delete(examId); } }

io.on("connection", (socket) => {
  socket.on("find_match", async ({ examId }: { examId?: string }) => {
    if (!examId || typeof examId !== "string") return socket.emit("match_error", "Đề thi không hợp lệ.");
    leaveQueue(socket.id); const round = await loadRound(examId); if (!round) return socket.emit("match_error", "Không thể tải đề cho phòng PvP.");
    const queue = queues.get(examId) || []; const opponentId = queue.shift();
    if (!opponentId) { queues.set(examId, [socket.id]); socket.emit("match_searching", { examId }); return; }
    if (!io.sockets.sockets.has(opponentId)) { socket.emit("match_searching", { examId }); queues.set(examId, [socket.id]); return; }
    if (queue.length) queues.set(examId, queue); else queues.delete(examId);
    const opponent = io.sockets.sockets.get(opponentId)!; const roomId = randomUUID(); const startsAt = Date.now() + 2500;
    const [nameOne, nameTwo] = await Promise.all([resolvePlayerName(opponent), resolvePlayerName(socket)]);
    const players = new Map<string, Player>([[opponent.id, { id: opponent.id, name: nameOne, answers: {}, score: 0, finished: false }], [socket.id, { id: socket.id, name: nameTwo, answers: {}, score: 0, finished: false }]]);
    let room: Room;
    const timeout = setTimeout(() => endRoom(room, "time_up"), 2500 + round.durationSeconds * 1000);
    room = { id: roomId, round, startsAt, players, timeout };
    rooms.set(roomId, room); socketRoom.set(opponent.id, roomId); socketRoom.set(socket.id, roomId); opponent.join(roomId); socket.join(roomId); io.to(roomId).emit("match_found", state(room));
  });
  socket.on("answer", ({ questionId, option }: { questionId?: string; option?: Option }) => {
    const roomId = socketRoom.get(socket.id); const room = roomId ? rooms.get(roomId) : null; const player = room?.players.get(socket.id);
    if (!room || !player || player.finished || typeof questionId !== "string" || !["A", "B", "C", "D"].includes(option || "") || !room.round.questionIds.includes(questionId)) return;
    player.answers[questionId] = option!; player.score = Object.entries(player.answers).reduce((total, [id, answer]) => total + (room.round.keys[id] === answer ? 1 : 0), 0);
    io.to(room.id).emit("score_update", state(room));
  });
  socket.on("finish_match", () => {
    const roomId = socketRoom.get(socket.id); const room = roomId ? rooms.get(roomId) : null; const player = room?.players.get(socket.id); if (!room || !player) return;
    player.finished = true; io.to(room.id).emit("score_update", state(room)); if ([...room.players.values()].every((entry) => entry.finished)) endRoom(room, "completed");
  });
  socket.on("cancel_match", () => leaveQueue(socket.id));
  socket.on("disconnect", () => {
    leaveQueue(socket.id); const roomId = socketRoom.get(socket.id); const room = roomId ? rooms.get(roomId) : null;
    if (!room) return; socketRoom.delete(socket.id); room.players.delete(socket.id); if (room.players.size) endRoom(room, "forfeit"); else { clearTimeout(room.timeout); rooms.delete(room.id); }
  });
});

httpServer.listen(port, () => console.log(`Socket.io PvP server listening on :${port}`));
