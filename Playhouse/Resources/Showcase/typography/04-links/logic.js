export const initialState = { clicks: 0 };

export const actions = {
  clicked(state) {
    state.clicks += 1;
  }
};
