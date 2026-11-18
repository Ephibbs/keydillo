const { PrismaClient } = require('@prisma/client');
(async () => {
  const p = new PrismaClient();
  await p.note.create({ data: { text: 'hello' } });
  console.log('prisma count', await p.note.count());
  await p.$disconnect();
})().catch(e => { console.log('prisma error', e.message); process.exit(1); });
