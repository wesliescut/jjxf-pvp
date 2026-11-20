// Separate Pages endpoint for the existing room Worker. The personal site is untouched.
export default {
  async fetch(request, env) {
    return env.LOBBY.fetch(request);
  },
};
