# Third-Party Notices

Conductor reimplements ideas, in its own words, from the two projects below. No
source code from either project was copied into the installed kit (the
payload that install.sh ships), and reimplementing an idea in different
prose does not by itself trigger any license or copyright obligation. The
repo-side `bench/` benchmark harness, which is never shipped by the
installer, adapts the structure of Honey's own benchmark harness under MIT;
see the Honey section below for that detail. These notices are included
anyway, both because the MIT license requires the copyright and permission
notice to accompany copies of the software (not applicable to the installed
kit, since no code was copied there) and as credit for the ideas.

## Ponytail

- URL: https://github.com/DietrichGebert/ponytail
- Copyright (c) 2026 DietrichGebert
- Idea absorbed: the decision ladder that stops at the first rung asking "do I
  need code at all", favoring the minimal-code answer over the elaborate one.

## Honey

- URL: https://github.com/Green-PT/honey-for-devs
- Copyright (c) 2026 Green-PT
- Idea absorbed: terse-output discipline and compact columnar agent handoffs
  that declare a row count as a checksum.
- The repo-side `bench/` benchmark harness (tasks, runner, and report
  layout) is modeled on the structure of Honey's own benchmark harness
  under `bench/`: no source code was copied into the installed kit, and no
  code from that harness was copied here either; only the directory
  layout and reporting shape were borrowed as ideas, in the same spirit
  as the rest of this file.

### Exclusion

Honey also ships carbon and energy estimation components (MPL-2.0,
EcoLogits-derived). Conductor did not use, copy, or derive any code, data, or
method from those components.

## MIT License

The following license text applies as published by each project above, with
that project's copyright line shown in its section.

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```
