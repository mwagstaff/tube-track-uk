export function scheduledBoardRequest(board) {
    if (!board.destinationIDs?.length) return null;
    return { originID: board.hubId, destinationIDs: board.destinationIDs, lineIDs: [board.lineId],
        ...(board.direction !== 'any' ? { direction: board.direction[0].toUpperCase() + board.direction.slice(1) } : {}) };
}

