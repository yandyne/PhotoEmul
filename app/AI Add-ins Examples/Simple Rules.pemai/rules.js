#!/usr/bin/osascript -l JavaScript
// PhotoEmul example add-in: no model, just keywords. Reads one OpenAI-style request on stdin,
// prints one reply. Tools come as ```json blocks because the manifest says "tools": false.
ObjC.import('Foundation')

function run() {
  const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile
  const req = JSON.parse($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js)
  const msgs = req.messages
  const text = m => typeof m.content === 'string' ? m.content : (m.content || []).map(c => c.text || '').join(' ')
  const reply = s => JSON.stringify({ choices: [{ message: { role: 'assistant', content: s } }] })

  // Second turn: the results of our block came back.
  if (msgs.some(m => m.role === 'assistant')) return reply('Done.')

  const ask = text(msgs[msgs.length - 1]).toLowerCase()
  const rules = [
    [/warm|따뜻|가을|autumn|golden/, { filterYShift: -12 }, 'Warmer'],
    [/cool|차갑|cold|blue|파랗/, { filterYShift: 12 }, 'Cooler'],
    [/green|초록/, { filterMShift: 10 }, 'Greener'],
    [/magenta|분홍|pink/, { filterMShift: -10 }, 'More magenta'],
  ]
  const hit = rules.find(r => r[0].test(ask))
  if (!hit) return reply('I only know: warm, cool, green, magenta.')
  const call = { tool: 'set', arguments: { values: hit[1], label: hit[2], note: 'Simple Rules example add-in' } }
  return reply(hit[2] + ':\n```json\n' + JSON.stringify(call) + '\n```')
}
