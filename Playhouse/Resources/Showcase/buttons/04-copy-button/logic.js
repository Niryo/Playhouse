export const initialState = { copies: 0 };

export const actions = {
  copied(state) {
    state.copies += 1;
  }
};
