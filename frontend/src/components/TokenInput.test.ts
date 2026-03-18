import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import TokenInput from './TokenInput.vue'

const options = [
  { id: 'prime',         name: 'Prime'         },
  { id: 'manufacturing', name: 'Manufacturing'  },
  { id: 'angus',         name: 'Angus'          },
]

const selected = [
  { id: 'prime', name: 'Prime' },
]

const baseProps = { selected, options: options.filter(o => o.id !== 'prime') }

describe('TokenInput', () => {

  it('renders a token for each selected item', () => {
    const wrapper = mount(TokenInput, { props: baseProps })
    expect(wrapper.findAll('.token')).toHaveLength(1)
    expect(wrapper.find('.token').text()).toContain('Prime')
  })

  it('shows no dropdown when not focused', () => {
    const wrapper = mount(TokenInput, { props: baseProps })
    expect(wrapper.find('.token-dropdown').exists()).toBe(false)
  })

  it('shows dropdown with options on focus', async () => {
    const wrapper = mount(TokenInput, { props: baseProps })
    await wrapper.find('.token-query').trigger('focus')
    expect(wrapper.find('.token-dropdown').exists()).toBe(true)
    expect(wrapper.findAll('.dropdown-item')).toHaveLength(2)  // manufacturing + angus
  })

  it('filters options as the user types', async () => {
    const wrapper = mount(TokenInput, { props: baseProps })
    await wrapper.find('.token-query').trigger('focus')
    await wrapper.find('.token-query').setValue('man')
    expect(wrapper.findAll('.dropdown-item')).toHaveLength(1)
    expect(wrapper.find('.dropdown-item').text()).toBe('Manufacturing')
  })

  it('emits add with the correct id when Enter is pressed on the highlighted item', async () => {
    const wrapper = mount(TokenInput, { props: baseProps })
    await wrapper.find('.token-query').trigger('focus')
    // First item is highlighted by default
    await wrapper.find('.token-query').trigger('keydown', { key: 'Enter' })
    expect(wrapper.emitted('add')).toHaveLength(1)
    expect(wrapper.emitted('add')![0]).toEqual(['manufacturing'])
  })

  it('emits add when a dropdown item is mousedown-clicked', async () => {
    const wrapper = mount(TokenInput, { props: baseProps })
    await wrapper.find('.token-query').trigger('focus')
    await wrapper.findAll('.dropdown-item')[1].trigger('mousedown')
    expect(wrapper.emitted('add')).toHaveLength(1)
    expect(wrapper.emitted('add')![0]).toEqual(['angus'])
  })

  it('clears the query and keeps dropdown open after adding', async () => {
    const wrapper = mount(TokenInput, { props: baseProps })
    await wrapper.find('.token-query').trigger('focus')
    await wrapper.find('.token-query').trigger('keydown', { key: 'Enter' })
    expect((wrapper.find('.token-query').element as HTMLInputElement).value).toBe('')
    expect(wrapper.find('.token-dropdown').exists()).toBe(true)
  })

  it('emits remove when a token × button is clicked', async () => {
    const wrapper = mount(TokenInput, { props: baseProps })
    await wrapper.find('.token-remove').trigger('click')
    expect(wrapper.emitted('remove')).toHaveLength(1)
    expect(wrapper.emitted('remove')![0]).toEqual(['prime'])
  })

  it('emits remove for the last token when Backspace is pressed with empty query', async () => {
    const wrapper = mount(TokenInput, { props: baseProps })
    await wrapper.find('.token-query').trigger('focus')
    await wrapper.find('.token-query').trigger('keydown', { key: 'Backspace' })
    expect(wrapper.emitted('remove')).toHaveLength(1)
    expect(wrapper.emitted('remove')![0]).toEqual(['prime'])
  })

  it('does not emit remove on Backspace when the query is non-empty', async () => {
    const wrapper = mount(TokenInput, { props: baseProps })
    await wrapper.find('.token-query').trigger('focus')
    await wrapper.find('.token-query').setValue('ma')
    await wrapper.find('.token-query').trigger('keydown', { key: 'Backspace' })
    expect(wrapper.emitted('remove')).toBeFalsy()
  })

  it('closes the dropdown and clears query on Escape', async () => {
    const wrapper = mount(TokenInput, { props: baseProps })
    await wrapper.find('.token-query').trigger('focus')
    await wrapper.find('.token-query').setValue('man')
    await wrapper.find('.token-query').trigger('keydown', { key: 'Escape' })
    expect(wrapper.find('.token-dropdown').exists()).toBe(false)
    expect((wrapper.find('.token-query').element as HTMLInputElement).value).toBe('')
  })

  it('shows placeholder only when nothing is selected', () => {
    const withPlaceholder = mount(TokenInput, {
      props: { selected: [], options, placeholder: 'add types…' },
    })
    expect((withPlaceholder.find('.token-query').element as HTMLInputElement).placeholder).toBe('add types…')

    const withSelected = mount(TokenInput, { props: { selected, options, placeholder: 'add types…' } })
    expect((withSelected.find('.token-query').element as HTMLInputElement).placeholder).toBe('')
  })

  it('shows no dropdown when all options are selected and query is empty', async () => {
    const wrapper = mount(TokenInput, { props: { selected, options: [] } })
    await wrapper.find('.token-query').trigger('focus')
    expect(wrapper.find('.token-dropdown').exists()).toBe(false)
  })

})
