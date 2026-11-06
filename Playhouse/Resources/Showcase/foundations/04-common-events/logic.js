export const initialState = { count: 0 };

export const actions = {
  tapped(state) {
    state.count += 1;
  }
};
