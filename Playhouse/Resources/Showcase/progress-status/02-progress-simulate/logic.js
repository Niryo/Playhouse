export const initialState = { pct: 0, running: false, status: "ready" };

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export const actions = {
  async start(state) {
    state.running = true;
    state.status = "uploading";
    while (state.pct < 100) {
      await sleep(50);
      state.pct += 5;
    }
    state.running = false;
    state.status = "done";
  },
  reset(state) {
    state.pct = 0;
    state.status = "ready";
  }
};
