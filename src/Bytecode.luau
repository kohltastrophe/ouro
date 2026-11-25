--!strict
--- Bytecode codec, disassembler, verifier, opcode tables, and instruction helpers for Luau `v3`–`v14` bytecode.
local BytecodeBuilder = require("./BytecodeBuilder")
local BytecodeCodec = require("./BytecodeCodec")
local BytecodeDefs = require("./BytecodeDefs")
local BytecodeDisassembler = require("./BytecodeDisassembler")
local Types = require("./Types")

type BytecodeDecoder = Types.BytecodeDecoder
type BytecodeEncoder = Types.BytecodeEncoder
type Proto = Types.Proto
type ProtoModule = Types.ProtoModule

local cachedVerifier: { verify: (string | buffer | ProtoModule, BytecodeDecoder?) -> (boolean, string?) }? = nil

local function verify(input: string | buffer | ProtoModule, decoder: BytecodeDecoder?): (boolean, string?)
	if cachedVerifier == nil then
		cachedVerifier = require("./VM/Verifier") :: any
	end
	return (cachedVerifier :: any).verify(input, decoder)
end

--- Bytecode codec, disassembler, verifier, opcode tables, and instruction helpers for Luau `v3`–`v14` bytecode.
local Bytecode = {
	--- Disassembles binary Luau bytecode or a `ProtoModule` into human-readable listings, throwing on corrupt input.
	disassemble = BytecodeDisassembler.disassemble :: (
		input: string | buffer | ProtoModule,
		dumpFlags: number?,
		source: string?,
		decoder: BytecodeDecoder?
	) -> string,
	--- Decodes binary Luau bytecode (`v3`–`v14` and `v100`) into an immutable `ProtoModule`.
	deserialize = BytecodeCodec.deserialize :: (bytecode: string | buffer, decoder: BytecodeDecoder?) -> (ProtoModule?, string?),
	--- Encodes a `ProtoModule` back into binary Luau bytecode with an optional opcode encoder.
	serialize = BytecodeCodec.serialize :: (protoModule: ProtoModule, encoder: BytecodeEncoder?) -> (string?, string?),
	--- Validates binary bytecode or a `ProtoModule` statically without instantiating a closure.
	verify = verify,
	--- Unpacks delta-encoded line numbers and per-proto baseline offsets for a `Proto`.
	decodeLineInfo = BytecodeCodec.decodeLineInfo :: (proto: Proto) -> ({ number }?, { number }?),
	--- Formats a compiler or parser error message as a status-zero binary bytecode payload.
	encodeError = BytecodeCodec.encodeError :: (message: string) -> string,
	--- Extracts the error message from a status-zero bytecode payload, or `nil` for valid bytecode.
	decodeError = BytecodeCodec.decodeError :: (bytecode: string | buffer) -> string?,
	--- Computes the Luau bytecode string hash for an identifier or string constant.
	getStringHash = BytecodeBuilder.getStringHash :: (str: string) -> number,
	--- Packs 1 to 3 string constant indices into a 32-bit `LOP_GETIMPORT` identifier.
	getImportId = BytecodeBuilder.getImportId :: (id0: number, id1: number?, id2: number?) -> number,
	--- Unpacks a 32-bit `LOP_GETIMPORT` identifier into `(count, id0, id1, id2)`.
	decomposeImportId = BytecodeCodec.decomposeImportId :: (ids: number) -> (number, number, number, number),
	--- Extracts the opcode byte (`0..255`) from a 32-bit bytecode instruction word.
	insnOp = BytecodeCodec.insnOp :: (insn: number) -> number,
	--- Extracts operand A (`8`-bit unsigned) from a 32-bit bytecode instruction word.
	insnA = BytecodeCodec.insnA :: (insn: number) -> number,
	--- Extracts operand B (`8`-bit unsigned) from a 32-bit bytecode instruction word.
	insnB = BytecodeCodec.insnB :: (insn: number) -> number,
	--- Extracts operand C (`8`-bit unsigned) from a 32-bit bytecode instruction word.
	insnC = BytecodeCodec.insnC :: (insn: number) -> number,
	--- Extracts signed 16-bit operand D from a 32-bit bytecode instruction word.
	insnD = BytecodeCodec.insnD :: (insn: number) -> number,
	--- Extracts signed 24-bit operand E from a 32-bit bytecode instruction word.
	insnE = BytecodeCodec.insnE :: (insn: number) -> number,
	--- Map of upstream `LOP_*` instruction names to numeric opcodes.
	Opcodes = BytecodeDefs.Opcodes,
	--- Reverse lookup table from numeric opcode to instruction name.
	opcodeNames = BytecodeDefs.opcodeNames,
	--- Instruction word length (`1` or `2`) keyed by numeric opcode.
	opLengths = BytecodeDefs.opLengths,
	--- Map of upstream `LBF_*` fastcall builtin names to numeric IDs.
	Builtins = BytecodeDefs.Builtins,
	--- Reverse lookup table from numeric builtin ID to function name.
	builtinNames = BytecodeDefs.builtinNames,
	--- Bytecode format version limits and constant/type tag constants (`LBC_*`).
	Tags = BytecodeDefs.Tags,
	--- Encoded bytecode type tags (`LBC_TYPE_*`).
	Types = BytecodeDefs.Types,
	--- Upvalue capture mode tags (`LCT_*`).
	Captures = BytecodeDefs.Captures,
	--- Function prototype flag bitmasks (`LPF_*`).
	ProtoFlags = BytecodeDefs.ProtoFlags,
	--- Inline feedback entry type tags (`LFT_*`).
	FeedbackTypes = BytecodeDefs.FeedbackTypes,
	--- Bitmask flags controlling `disassemble` and compiler dump output.
	DumpFlags = BytecodeBuilder.DumpFlags,
}

return table.freeze(Bytecode)
